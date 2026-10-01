import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/text_filter.dart';

void main() {
  group('TextFilterRule', () {
    test('round-trips through a map', () {
      const rule = TextFilterRule(
        id: 'r1',
        pattern: r'^\s*support me\b.*',
        label: 'Support me',
      );
      final back = TextFilterRule.fromMap(rule.toMap());
      expect(back, isNotNull);
      expect(back!.id, 'r1');
      expect(back.pattern, rule.pattern);
      expect(back.isRegex, isTrue);
      expect(back.isEnabled, isTrue);
    });

    test('drops a stored entry with no pattern or no id', () {
      expect(TextFilterRule.fromMap({'id': 'a'}), isNull);
      expect(TextFilterRule.fromMap({'pattern': 'x'}), isNull);
      expect(TextFilterRule.fromMap('not a map'), isNull);
    });

    test('encodes and decodes a list, skipping one bad entry', () {
      final rules = [
        const TextFilterRule(id: 'a', pattern: 'x', label: 'A'),
        const TextFilterRule(id: 'b', pattern: 'y', label: 'B'),
      ];
      final encoded = encodeTextFilterRules(rules);
      expect(decodeTextFilterRules(encoded).map((r) => r.id), ['a', 'b']);
      // One corrupt entry costs one rule, not the set.
      expect(
        decodeTextFilterRules('[{"id":"a","pattern":"x"},7,{"pattern":"z"}]')
            .map((r) => r.id),
        ['a'],
      );
      expect(decodeTextFilterRules('not json'), isEmpty);
      expect(decodeTextFilterRules('{"a":1}'), isEmpty);
      expect(decodeTextFilterRules(null), isEmpty);
    });

    group('hiddenSentence', () {
      test('escapes the sentence and bounds it to word edges', () {
        final rule = TextFilterRule.hiddenSentence(
          'The End (vol. 3). Thanks!',
          id: 'h1',
        );
        // Every character that means something in a regex is escaped, so the
        // rule matches the sentence rather than a pattern shaped like it.
        expect(rule.pattern, r'(?<![\w])The End \(vol\. 3\)\. Thanks!(?![\w])');
        expect(
          RegExp(rule.pattern, caseSensitive: false).hasMatch(
            '  The End (vol. 3). Thanks!  ',
          ),
          isTrue,
        );
      });

      test('matches inside a longer line, which is the bug it had', () {
        // Two pieces of injected text on one line. The long press reports one
        // of them, so a line-anchored rule could never fire: hiding it saved the
        // rule, re-ran the filter, and left the text exactly where it was.
        final rule = TextFilterRule.hiddenSentence(
          'Read at novelsb.com!',
          id: 'h1',
        );
        final re = RegExp(rule.pattern, caseSensitive: false, multiLine: true);
        expect(
          re.hasMatch('If you like it, read at novelsb.com! New chapters daily.'),
          isTrue,
        );
      });

      test('still refuses to cut mid-word', () {
        final rule = TextFilterRule.hiddenSentence('The End', id: 'h1');
        final re = RegExp(rule.pattern, caseSensitive: false, multiLine: true);
        expect(re.hasMatch('The End'), isTrue);
        expect(re.hasMatch('And then came The End of it all.'), isTrue);
        // "The Endeavour" contains "The End" - that must not count.
        expect(re.hasMatch('The Endeavour began.'), isFalse);
      });

      test('trims before escaping, and labels a long sentence briefly', () {
        final rule = TextFilterRule.hiddenSentence('  short  ', id: 'h1');
        expect(rule.pattern, r'(?<![\w])short(?![\w])');
        final long = TextFilterRule.hiddenSentence('x' * 60, id: 'h2');
        expect(long.label.contains('…'), isTrue);
        expect(long.label.length, lessThan(50));
      });
    });
  });

  group('TextFilterEngine', () {
    TextFilterEngine engineFor(List<TextFilterRule> rules) =>
        TextFilterEngine(rules);

    test('is empty with no rules, and short-circuits', () {
      expect(engineFor(const []).isEmpty, isTrue);
      expect(TextFilterEngine(const []).isEmpty, isTrue);
    });

    test('skips a disabled rule rather than applying it', () {
      final engine = engineFor([
        TextFilterRule(
          id: 'off',
          pattern: r'ad\b',
          isEnabled: false,
          label: 'off',
        ),
      ]);
      expect(engine.isEmpty, isTrue);
      expect(engine.isFiltered('an ad here'), isFalse);
    });

    test('skips a rule whose regex does not compile', () {
      final engine = engineFor([
        const TextFilterRule(id: 'bad', pattern: '([unclosed', label: 'bad'),
        const TextFilterRule(id: 'ok', pattern: r'patreon\b', label: 'ok'),
      ]);
      // The broken one is dropped; the set still works.
      expect(engine.isFiltered('see patreon.com/x'), isTrue);
      expect(engine.isFiltered('nothing to see'), isFalse);
    });

    test('matches case-insensitively', () {
      final engine = engineFor([
        const TextFilterRule(id: 'p', pattern: r'patreon\.com', label: 'p'),
      ]);
      expect(engine.isFiltered('Go to PATREON.COM today'), isTrue);
    });

    test('matches a literal, case-insensitively, every occurrence', () {
      final engine = engineFor([
        const TextFilterRule(
          id: 'lit',
          pattern: 'bad line',
          isRegex: false,
          label: 'lit',
        ),
      ]);
      final cuts = engine.findFilteredRanges('bad line here, and a bad line');
      expect(cuts, hasLength(2));
      expect(engine.stripFiltered('a bad line b'), 'a b');
    });

    group('line anchoring', () {
      // The reason rules are also evaluated per line: `^` has to mean "start of
      // this line", or a footer rule would swallow the rest of the chapter.
      final engine = engineFor([
        const TextFilterRule(
          id: 'footer',
          pattern: r'^\s*join our discord\b.*',
          label: 'footer',
        ),
      ]);

      test('fires on the line it anchors to', () {
        expect(engine.isFiltered('Join our discord for more'), isTrue);
      });

      test('leaves the rest of the chapter alone', () {
        const chapter =
            'The fight ended.\nJoin our discord for more\nThe sun rose.';
        expect(engine.stripFiltered(chapter), 'The fight ended.\nThe sun rose.');
      });

      test('does not fire mid-line', () {
        expect(engine.isFiltered('he said join our discord'), isFalse);
      });
    });

    group('stripFiltered', () {
      test('returns null when nothing matched, so styling is kept', () {
        final engine = engineFor([
          const TextFilterRule(id: 'a', pattern: r'patreon\b', label: 'a'),
        ]);
        expect(engine.stripFiltered('Nothing here to remove.'), isNull);
        expect(engine.stripFiltered('   '), isNull);
      });

      test('absorbs the separators around a cut, leaving no debris', () {
        final engine = engineFor([
          const TextFilterRule(id: 'a', pattern: 'ONE', label: 'a'),
        ]);
        // The naive cut would leave "start , TWO end".
        expect(engine.stripFiltered('start ONE, TWO end'), 'start TWO end');
      });

      test('puts a space back when absorbing would glue two words', () {
        final engine = engineFor([
          const TextFilterRule(id: 'a', pattern: r'\[X\]', label: 'a'),
        ]);
        expect(engine.stripFiltered('foo [X] bar'), 'foo bar');
      });

      test('returns an empty string when the whole input is covered', () {
        final engine = engineFor([
          const TextFilterRule(id: 'a', pattern: r'.*', label: 'a'),
        ]);
        expect(engine.stripFiltered('anything at all'), '');
      });

      test('collapses the whitespace a cut leaves behind', () {
        final engine = engineFor([
          const TextFilterRule(id: 'a', pattern: 'ad', label: 'a'),
        ]);
        expect(engine.stripFiltered('keep  ad  keep'), 'keep keep');
      });

      test('drops an unbalanced quote left dangling by a cut', () {
        final engine = engineFor([
          const TextFilterRule(id: 'a', pattern: 'AD', label: 'a'),
        ]);
        expect(engine.stripFiltered('he said "AD'), 'he said');
      });

      test('leaves nothing behind when only punctuation is left', () {
        final engine = engineFor([
          const TextFilterRule(id: 'a', pattern: 'AD', label: 'a'),
        ]);
        // `""` and `---` are debris, not prose: the paragraph was the ad.
        expect(engine.stripFiltered('"AD"'), '');
        expect(engine.stripFiltered('--- AD ---'), '');
        expect(engine.stripFiltered('"AD" kept'), 'kept');
      });

      test('merges overlapping rules into one range', () {
        final engine = engineFor([
          const TextFilterRule(id: 'a', pattern: 'abc', label: 'a'),
          const TextFilterRule(id: 'b', pattern: 'cde', label: 'b'),
        ]);
        expect(engine.findFilteredRanges('xxabcdexx'), hasLength(1));
        // The words either side of the cut survive, separated by the single
        // space the re-space rule puts back.
        expect(engine.stripFiltered('xxabcdexx'), 'xx xx');
      });

      test('merges ranges that only touch, not just overlap', () {
        final engine = engineFor([
          const TextFilterRule(id: 'a', pattern: 'abc', label: 'a'),
          const TextFilterRule(id: 'b', pattern: 'def', label: 'b'),
        ]);
        expect(engine.stripFiltered('abcdef'), '');
      });

      test('cuts are reported sorted, and grown over the space beside them', () {
        final engine = engineFor([
          const TextFilterRule(id: 'a', pattern: 'zz', label: 'a'),
        ]);
        final cuts = engine.findFilteredRanges('abzz cd zz');
        // The second range starts at 7, not 8: it absorbed the space in front
        // of it, which is what stops "cd  zz" keeping a double space.
        expect(cuts.map((c) => c.start), [2, 7]);
        // The first grew *right* over the space, so it covers three characters.
        expect(cuts.first.end - cuts.first.start, 3);
        expect(engine.stripFiltered('abzz cd zz'), 'ab cd');
      });

      test('a cut does not absorb across a line boundary', () {
        final engine = engineFor([
          const TextFilterRule(id: 'a', pattern: r'^\s*AD\b.*', label: 'a'),
        ]);
        // Absorbing the newline would glue the paragraph above onto the one
        // below, which reads as one long sentence that nobody wrote. The blank
        // line that is left is what a removed paragraph looks like.
        expect(
          engine.stripFiltered('The first line.\nAD\nThe third line.'),
          'The first line.\nThe third line.',
        );
      });

      test('keeps the full stop that ends the chapter', () {
        final engine = engineFor([
          const TextFilterRule(id: 'a', pattern: r'^\s*AD\b.*', label: 'a'),
        ]);
        // Tidy trims edge punctuation, and a full stop is punctuation: in the
        // trim set it took the end off the last sentence of every chapter the
        // rules touched.
        expect(engine.stripFiltered('The first line.\nAD'), 'The first line.');
      });
    });

    group('built-in rules', () {
      TextFilterEngine builtins() =>
          TextFilterEngine(builtinTextFilterRules);

      // Each of these is a real injected line from a real source, which is the
      // only test data worth having: an ad that does not look like the ads in
      // the wild is not the case that was broken.
      const cases = <String, String>{
        'Discord invite': 'Join our discord for more chapters!',
        'Patreon': 'Please support me on Patreon',
        'my patreon': 'My Patreon: patreon.com/someone',
        'Ko-fi line': 'ko-fi.com/someone',
        'donation plea': 'Please support me!',
        'community': 'Join my telegram group for updates',
        'thanks': 'Thanks for reading!',
        'url line': 'https://novelfull.com/whatever',
        'bare domain': 'www.novelfull.com',
        'voting': 'Please vote for this novel on top novels',
        'read next chapter': 'Read the next chapter at www.example.com',
        'read no': 'Read N° 12 on our discord',
        'previous chapter nav': 'Previous chapter / Next chapter',
        'chapter n of m': 'Chapter 4 of 480',
        'click here': 'Click here to read the next chapter',
        'translation credit': 'Translation by someone',
        'translator credit': 'Translator: BornToBe',
        'translator colon': 'Translation: someone',
        'TL credit': 'TL: someone',
        'T/N credit': 'T/N: someone',
        'editor dash': 'Editor - someone',
        'proofreader': 'Proofread by: someone',
        'novel promo': 'Check out my other novels!',
        'if you enjoy': 'If you enjoyed this novel, consider supporting it',
        'follow me': 'Follow me on twitter',
        'email': 'translator@example.com',
      };

      cases.forEach((label, line) {
        test('strips $label', () {
          expect(builtins().isFiltered(line), isTrue, reason: line);
          expect(builtins().stripFiltered(line)?.trim(), isEmpty);
        });
      });

      test('removes a bare link without eating the sentence around it', () {
        // Deliberately conservative, and the reason is the false positive on the
        // other side: a line of prose that merely mentions a link is a line of
        // the story, and no reader wants a filter that deletes it. The link goes;
        // the words stay.
        expect(
          builtins().stripFiltered('chat with us at discord.gg/abcd'),
          'chat with us at',
        );
      });

      test('leaves ordinary prose alone', () {
        // Every one of these has been a false positive in a reader, which is
        // the failure that makes people switch a feature off for good.
        const prose = [
          'He asked her to support him, and she did.',
          'They read the next chapter before bed.',
          'The previous chapter had ended in blood.',
          'Chapter 4 of the book was the best one.',
          'She joined the discord server at school.',
          'I support me, I do.',
          'He followed me out the door.',
          'Mr. Smith translated it badly.',
          "The translator's note explained the change.",
        ];
        final engine = builtins();
        for (final line in prose) {
          expect(engine.isFiltered(line), isFalse, reason: line);
        }
      });

      test('keeps a paragraph of prose with one ad line out of it', () {
        const chapter =
            'The rain had not stopped since dawn.\n'
            'Please support me on Patreon!\n'
            'By noon the river had burst its banks.';
        expect(
          builtins().stripFiltered(chapter),
          'The rain had not stopped since dawn.\nBy noon the river had burst its banks.',
        );
      });

      test('every built-in id is unique', () {
        final ids = builtinTextFilterRules.map((r) => r.id).toList();
        expect(ids.toSet(), hasLength(ids.length));
      });

      test('every built-in pattern compiles', () {
        for (final rule in builtinTextFilterRules) {
          expect(() => RegExp(rule.pattern), returnsNormally, reason: rule.id);
        }
      });
    });
  });
}
