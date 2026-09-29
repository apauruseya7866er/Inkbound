import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/tts/narration_filter.dart';
import 'package:watch_app/core/reading/tts/sentence_parser.dart';

/// What read-aloud actually says for a chapter, as one string.
String spoken(String html) =>
    SentenceParser.parseHtml(html).sentences.map((s) => s.text).join(' | ');

void main() {
  group('suppressed entirely', () {
    void skipped(String html) {
      expect(
        spoken(html),
        isEmpty,
        reason: 'expected nothing spoken for: $html',
      );
    }

    test('donation and community pleas', () {
      skipped('<p>Please support me on Patreon!</p>');
      skipped('<p>You can also support me on ko-fi.com!</p>');
      skipped('<p>Join my Discord server for updates!</p>');
      skipped('<p>Check out our telegram group.</p>');
      skipped('<p>Please rate this novel on NovelUpdates!</p>');
      skipped('<p>Thanks for reading!</p>');
    });

    test('links, alone and inside a sentence', () {
      skipped('<p>https://novelbin.com/novel/12345</p>');
      skipped('<p>Read more at https://patreon.com/author today.</p>');
      skipped('<p>mail me at someone@example.com</p>');
    });

    test('scraper leftovers', () {
      skipped('<p>Previous chapter</p>');
      skipped('<p>Next chapter</p>');
      skipped('<p>Click here to read the next chapter.</p>');
      skipped('<p>If you find any errors (broken links) report it.</p>');
    });

    test('notes', () {
      skipped('<p>Author&apos;s Note: thanks for reading!</p>');
      skipped('<p>TL Note: the original used honorifics.</p>');
      skipped('<p>Editor&apos;s Note: fixed a typo.</p>');
      skipped('<p>PR: verified the translation.</p>');
      skipped('<p>[TN: The narrator is lying here.]</p>');
      skipped('<p>【重要】この章は筆者注を含む。</p>');
    });

    test('watermarks, spaced out to dodge scrapers', () {
      // Judged per block, not per sentence: the spaced form contains a full
      // stop, so sentence rules only ever see the first half and `c o m`
      // survives on its own.
      skipped('<p>Updated from F r e e w e b n o v e l . c o m</p>');
      skipped('<p>[Updated from Free Web Novel]</p>');
    });

    test('blocks with no prose in them at all', () {
      // Already handled by the letter gate before the filter existed, and kept
      // here so the filter cannot regress it.
      skipped('<p>***</p>');
      skipped('<p>---</p>');
      skipped('<p>===</p>');
      skipped('<p>12</p>');
      skipped('<p>...</p>');
    });
  });

  group('prose survives', () {
    test('an ad between two sentences takes only itself', () {
      // The case that decides the design. One paragraph, three sentences, and
      // the block cannot be dropped without losing the story either side of it.
      expect(
        spoken('<p>He drew his blade. Please support me on Patreon! '
            'The door opened.</p>'),
        'He drew his blade. | The door opened.',
      );
    });

    test('a paragraph opening "Note:" is prose, not a note', () {
      // "Note:" is a real sentence opener. Notes are only trusted at the ends
      // of a chapter, and even there a bare "Note:" is not claimed.
      expect(
        spoken('<p>Note: the door was already open.</p>'),
        'Note | the door was already open.',
      );
    });

    test('a body block that mentions an error is not boilerplate', () {
      expect(
        spoken('<p>He checked the code for errors, then found the bug.</p>'),
        contains('checked the code for errors'),
      );
    });

    test('a mid-chapter block starting "PR:" is kept', () {
      // Short tags are only trusted within two blocks of either end, where
      // notes actually live. Five blocks, so the middle one is out of reach of
      // both windows.
      const html = '<p>One thing happened.</p><p>Another happened.</p>'
          '<p>PR: two</p><p>A third happened.</p><p>A fourth happened.</p>';
      expect(spoken(html), contains('PR | two'));
    });

    test('text in brackets mid-sentence is not a note', () {
      expect(
        spoken('<p>She whispered [quietly] and he did not hear.</p>'),
        contains('whispered'),
      );
    });
  });

  group('note placement', () {
    test('a note after the title is dropped, the story is not', () {
      expect(
        spoken('<h1>Chapter 3</h1><p>TL: I fixed the names.</p>'
            '<p>Rain hit the roof.</p>'),
        contains('Rain hit the roof.'),
      );
      expect(
        spoken('<h1>Chapter 3</h1><p>TL: I fixed the names.</p>'
            '<p>Rain hit the roof.</p>'),
        isNot(contains('fixed the names')),
      );
    });

    test('a trailing note is dropped, the story is not', () {
      final out =
          spoken('<p>Rain hit the roof. It did not stop.</p>'
              "<p>Author's Note: see you next week!</p>");
      expect(out, 'Rain hit the roof. | It did not stop.');
    });

    test('every note spelling is recognised', () {
      const heads = <String>[
        "Author's Note:",
        'Authors Note:',
        'Author note:',
        "Editor's Note:",
        'TL:',
        'TL Note:',
        'TN:',
        'AN:',
        'A/N:',
        'PR:',
        'P/R:',
        'Note from the translator:',
      ];
      for (final head in heads) {
        expect(
          NarrationFilter.skipBlock(
            '$head a long rambling note about the edition.',
            blockIndex: 1,
            blockCount: 3,
          ),
          isTrue,
          reason: 'expected "$head" to be recognised as a note',
        );
      }
    });
  });

  group('URLs', () {
    // Long enough that the URL is not the bulk of the sentence, so what is
    // being tested is the mechanism rather than the "mostly a link" rule below.
    const withUrl = 'She clicked the link at https://a.co and the whole '
        'chapter dissolved into light behind her, leaving nothing but silence.';

    test('a scheme colon does not end a sentence', () {
      // The bug that motivated the whole sanitising pass: "https://" was cut in
      // half and the engine read "https" and then "//example dot com" as two
      // separate sentences.
      final s = SentenceParser.parseRaw(withUrl);
      expect(s, hasLength(1), reason: 'got ${s.map((e) => e.text).toList()}');
    });

    test('a URL is removed from the words actually spoken', () {
      final s = SentenceParser.parseRaw(withUrl);
      expect(s.first.text, isNot(contains('a.co')));
      expect(s.first.text, contains('dissolved into light'));
    });

    test('stripping a URL leaves the offsets alone', () {
      final s = SentenceParser.parseRaw(withUrl);
      expect(withUrl.substring(s.first.startIndex, s.first.endIndex), withUrl);
    });

    test('a sentence that was only a URL disappears', () {
      expect(SentenceParser.parseRaw('https://example.com'), isEmpty);
    });

    test('a sentence that is mostly a link is dropped, not half-spoken', () {
      // Sanitising alone leaves "mail me at", which passes every other check
      // and is worse than silence.
      expect(SentenceParser.parseRaw('mail me at someone@example.com'), isEmpty);
      expect(
        SentenceParser.parseRaw('Read more at https://patreon.com/author.'),
        isEmpty,
      );
    });

    test('star and backtick markup is not spoken', () {
      final s = SentenceParser.parseRaw('He **shouted** `loudly`.');
      expect(s.first.text, isNot(contains('*')));
      expect(s.first.text, isNot(contains('`')));
    });
  });

  group('NarrationFilter directly', () {
    test('blank input is skipped', () {
      expect(NarrationFilter.skipSentence('   '), isTrue);
      expect(NarrationFilter.skipSentence(''), isTrue);
    });

    test('a middle-of-chapter block is never judged a note', () {
      expect(
        NarrationFilter.skipBlock(
          "Author's Note: mid chapter.",
          blockIndex: 5,
          blockCount: 20,
        ),
        isFalse,
      );
      expect(
        NarrationFilter.skipBlock(
          "Author's Note: at the end.",
          blockIndex: 19,
          blockCount: 20,
        ),
        isTrue,
      );
      expect(
        NarrationFilter.skipBlock(
          "Author's Note: at the start.",
          blockIndex: 0,
          blockCount: 20,
        ),
        isTrue,
      );
    });

    test('a bracketed note is skipped wherever it is', () {
      expect(
        NarrationFilter.skipBlock(
          '[TN: a note]',
          blockIndex: 7,
          blockCount: 20,
        ),
        isTrue,
      );
    });

    test('sanitise leaves ordinary prose alone', () {
      expect(NarrationFilter.sanitise('He drew his blade.'), 'He drew his blade.');
    });
  });
}
