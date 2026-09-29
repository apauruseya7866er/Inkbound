import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/reader/novel_html.dart';
import 'package:watch_app/features/reader/novel_paginator.dart';
import 'package:watch_app/features/reader/tts_alignment.dart';

/// The highlight is only correct if a sentence's offsets point at the words it
/// actually contains. These tests assert that by reconstructing the highlighted
/// text and comparing it to the sentence, rather than by checking offsets — an
/// offset assertion can be satisfied by an off-by-one that still "looks right".
void main() {
  group('tokenizer parity', () {
    test('plain text survives tokenizing unchanged', () {
      final layout = NovelTextLayout.fromHtml('<p>Hello there.</p>');
      expect(layout.text, 'Hello there.\n');
    });

    test('a paragraph break becomes a newline', () {
      final layout = NovelTextLayout.fromHtml('<p>One.</p><p>Two.</p>');
      expect(layout.text, 'One.\nTwo.\n');
    });

    test('a soft break is a newline but not a block boundary', () {
      final layout = NovelTextLayout.fromHtml('<p>Line one<br>Line two</p>');
      expect(layout.text, 'Line one\nLine two\n');
      // Both lines are one block, so a sentence spanning them is one block.
      expect(layout.blockAt(0), 0);
      expect(layout.blockAt(layout.text.indexOf('Line two')), 0);
    });

    test('block index counts paragraph breaks', () {
      final layout = NovelTextLayout.fromHtml('<p>One.</p><p>Two.</p><p>Three.</p>');
      expect(layout.blockAt(layout.text.indexOf('One')), 0);
      expect(layout.blockAt(layout.text.indexOf('Two')), 1);
      expect(layout.blockAt(layout.text.indexOf('Three')), 2);
    });

    test('inline styling is preserved and does not add characters', () {
      final layout = NovelTextLayout.fromHtml('<p>He said <b>loudly</b> now.</p>');
      expect(layout.text, 'He said loudly now.\n');
      final styled = layout.tokens.where((t) => !t.isBreak && t.bold);
      expect(styled, isNotEmpty);
    });

    test('a styled run keeps its own offset in the rendered text', () {
      final layout = NovelTextLayout.fromHtml('<p>He said <b>loudly</b> now.</p>');
      final ranges = layout.rangesFor(
        layout.text.indexOf('loudly'),
        layout.text.indexOf('loudly') + 'loudly'.length,
      );
      expect(ranges, hasLength(1));
      final r = ranges.single;
      expect(layout.tokens[r.token].text.substring(r.start, r.end), 'loudly');
    });

    test('a range spanning two styled runs returns two ranges', () {
      final layout = NovelTextLayout.fromHtml('<p><b>He said</b> loudly.</p>');
      final ranges = layout.rangesFor(0, layout.text.indexOf('loudly') + 2);
      expect(ranges.length, greaterThanOrEqualTo(2));
    });
  });

  group('sentence alignment', () {
    test('a sentence range selects exactly its own text', () {
      const html = '<p>First one here. Second one there. Third one here.</p>';
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      final text = aligned.layout.text;

      expect(aligned.total, 3);
      for (final s in aligned.sentences) {
        final slice = text.substring(s.startIndex, s.endIndex);
        // The range must cover the sentence's words. Normalisation strips
        // quotes, so compare on the letters rather than the exact punctuation.
        final words = s.text.replaceAll(RegExp(r'[^\w\s]'), '');
        expect(
          slice.replaceAll(RegExp(r'[^\w\s]'), ''),
          words,
          reason: 'sentence ${s.index} range does not cover its own text',
        );
      }
    });

    test('ranges are contiguous and ordered', () {
      const html = '<p>One here. Two here. Three here. Four here.</p>';
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      for (var i = 1; i < aligned.sentences.length; i++) {
        expect(
          aligned.sentences[i].startIndex,
          greaterThanOrEqualTo(aligned.sentences[i - 1].endIndex),
        );
      }
    });

    test('indices start at zero and are contiguous', () {
      const html = '<p>One. Two. Three. Four. Five.</p>';
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      expect(
        aligned.sentences.map((s) => s.index).toList(),
        List.generate(aligned.total, (i) => i),
      );
    });

    test('a sentence spanning paragraphs is attributed to where it starts', () {
      // A trailing open quote/paren style construct is contrived, so use a
      // sentence that simply runs across a soft break.
      const html = '<p>He began to say<br>that it was over. Then silence.</p>';
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      expect(aligned.total, greaterThanOrEqualTo(1));
      for (final s in aligned.sentences) {
        expect(s.blockIndex, 0);
      }
    });

    test('sentences in later paragraphs get later block indices', () {
      const html = '<p>First block here.</p><p>Second block here.</p>';
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      expect(aligned.sentences.first.blockIndex, 0);
      expect(aligned.sentences.last.blockIndex, 1);
    });

    test('an empty chapter aligns to nothing', () {
      final aligned = alignChapter(NovelTextLayout.fromHtml(''));
      expect(aligned.isEmpty, isTrue);
    });

    test('offsets are not shifted by whitespace normalisation', () {
      // The reason parseRaw exists. Had the text been preprocessed first, the
      // run of spaces would have collapsed and every offset after it would point
      // one or more characters away from the words the page actually shows.
      const html = '<p>He   waited.  And then he stopped.</p>';
      final layout = NovelTextLayout.fromHtml(html);
      final aligned = alignChapter(layout);

      expect(aligned.total, 2);

      // The range keeps the page's own spacing, verbatim.
      final first = layout.text.substring(
        aligned.sentences.first.startIndex,
        aligned.sentences.first.endIndex,
      );
      expect(first, 'He   waited.');

      // And it still covers exactly the words that are spoken.
      for (final s in aligned.sentences) {
        final slice = layout.text.substring(s.startIndex, s.endIndex);
        expect(
          slice.replaceAll(RegExp(r'[^\w]'), ''),
          s.text.replaceAll(RegExp(r'[^\w]'), ''),
          reason: 'sentence ${s.index} drifted from its own words',
        );
      }
    });
  });

  group('pageIndexForRange', () {
    const base = TextStyle(fontSize: 14);

    List<TextSpan> buildPages(String html, Size size) {
      final spans = <InlineSpan>[];
      for (final t in tokenizeNovelHtml(html)) {
        if (t.isBreak) {
          spans.add(const TextSpan(text: '\n'));
          continue;
        }
        spans.add(TextSpan(text: t.text, style: base));
      }
      return paginateSpans(
        TextSpan(style: base, children: spans),
        pageSize: size,
        style: base,
      );
    }

    test('a single page holds everything', () {
      final pages = buildPages('<p>One here. Two here.</p>', const Size(400, 4000));
      expect(pages, hasLength(1));
      expect(pageIndexForRange(pages, 0, 5), 0);
    });

    test('a later sentence resolves to its own page', () {
      final html = '<p>${'Sentence number here. ' * 60}</p>';
      final pages = buildPages(html, const Size(320, 220));
      expect(pages.length, greaterThan(2), reason: 'test needs several pages');

      final layout = NovelTextLayout.fromHtml(html);
      final aligned = alignChapter(layout);

      for (var i = 0; i < aligned.total; i++) {
        final r = aligned.rangeAt(i)!;
        final expected = _expectedPage(pages, layout.text, r.start);
        expect(
          pageIndexForRange(pages, r.start, r.end),
          expected,
          reason: 'sentence $i resolved to the wrong page',
        );
      }
    });

    test('every page is reachable by some sentence', () {
      final html = '<p>${'Sentence number here. ' * 60}</p>';
      final pages = buildPages(html, const Size(320, 220));
      final layout = NovelTextLayout.fromHtml(html);
      final aligned = alignChapter(layout);

      final seen = <int>{};
      for (var i = 0; i < aligned.total; i++) {
        final r = aligned.rangeAt(i)!;
        final p = pageIndexForRange(pages, r.start, r.end);
        if (p != null) seen.add(p);
      }
      // Auto-turning is pointless if the sentences never leave the page they
      // start on; this would mean the mapping is collapsing to page 0.
      expect(seen.length, greaterThan(1));
      expect(seen.every((p) => p >= 0 && p < pages.length), isTrue);
    });

    test('a sentence running past a page edge belongs to where it starts', () {
      final html = '<p>${'Sentence number here. ' * 60}</p>';
      final pages = buildPages(html, const Size(320, 220));

      // A range that starts on a page and runs past its end still reports the
      // starting page: turning to where the sentence began is the least jarring.
      final firstLen = pages.first.toPlainText().length;
      final target = pageIndexForRange(pages, firstLen - 5, firstLen + 50);
      expect(target, 0);
    });

    test('a range before the first page is null', () {
      final pages = buildPages('<p>Text here.</p>', const Size(400, 4000));
      expect(pageIndexForRange(pages, -10, 5), isNull);
    });

    test('a range past the last page is null', () {
      final pages = buildPages('<p>Text here.</p>', const Size(400, 4000));
      final total = pages.fold<int>(0, (a, p) => a + p.toPlainText().length);
      expect(pageIndexForRange(pages, total, total + 50), isNull);
    });

    test('an empty or inverted range is null', () {
      final pages = buildPages('<p>Text here.</p>', const Size(400, 4000));
      expect(pageIndexForRange(pages, 5, 5), isNull);
      expect(pageIndexForRange(pages, 9, 2), isNull);
    });

    test('no pages is null rather than a crash', () {
      expect(pageIndexForRange(const [], 0, 10), isNull);
    });

    test('agrees with the page the highlight lands on', () {
      // The two functions must not disagree: if the highlight paints page 2
      // while the auto-turn goes to page 3, the reader is shown a sentence they
      // cannot see.
      final html = '<p>${'Sentence number here. ' * 60}</p>';
      final pages = buildPages(html, const Size(320, 220));
      final layout = NovelTextLayout.fromHtml(html);
      final aligned = alignChapter(layout);
      final hl = const TextStyle(backgroundColor: _hl);

      for (var i = 0; i < aligned.total; i += 3) {
        final r = aligned.rangeAt(i)!;
        final decorated = highlightPages(
          pages,
          r.start,
          r.end,
          highlight: hl,
        );
        final highlightedOn = <int>{
          for (var p = 0; p < decorated.length; p++)
            if (_highlightedText(decorated[p]).isNotEmpty) p,
        };
        final turnedTo = pageIndexForRange(pages, r.start, r.end);
        expect(
          highlightedOn,
          contains(turnedTo),
          reason: 'sentence $i: turn target $turnedTo is not a highlighted '
              'page ($highlightedOn)',
        );
      }
    });
  });

  group('sentences never cross a block boundary', () {
    test('a heading followed by prose does not merge into the first sentence', () {
      // The regression this exists for: "Chapter 2: Comparison" has a colon,
      // the colon splits as a terminator, and the remainder ("Comparison") used
      // to run straight on into the next paragraph. Narration opened by
      // reading the chapter title glued to the first line of the story.
      const html = '<p>Chapter 2: Comparison</p>'
          '<p>Funny how much I hated the phrase, he thought, pushing the chair.</p>';
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));

      for (final s in aligned.sentences) {
        final slice = aligned.layout.text.substring(s.startIndex, s.endIndex);
        expect(
          slice.contains('\n'),
          isFalse,
          reason: 'sentence ${s.index} spans a paragraph boundary: "$slice"',
        );
      }
    });

    test('every sentence sits inside a single block', () {
      const html = '<p>First block here.</p><p>Second block here.</p>'
          '<p>Third block here.</p>';
      final layout = NovelTextLayout.fromHtml(html);
      final aligned = alignChapter(layout);

      for (final s in aligned.sentences) {
        expect(
          layout.blockAt(s.startIndex),
          layout.blockAt(s.endIndex - 1),
          reason: 'sentence ${s.index} crosses a block boundary',
        );
      }
    });

    test('a soft line break does NOT split a block', () {
      // Poetry and addresses live in one paragraph. Cutting on <br> would shred
      // a verse into one sentence per line, so a sentence here is *expected* to
      // span the soft break — the invariant is that it is not split, and that
      // the opening lines are not mistaken for a title and dropped.
      const html = '<p>Roses are red<br>Violets are blue</p>';
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      expect(aligned.total, 1);
      expect(aligned.sentences.single.text, contains('Roses are red'));
      expect(aligned.sentences.single.text, contains('Violets are blue'));
    });
  });

  group('headings are not narrated', () {
    test('a bare first-paragraph title is skipped', () {
      const html = '<p>Chapter 1</p>'
          '<p>A new day begins, and Kai Yang woke up. He cleaned up the room.</p>';
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));

      expect(
        aligned.sentences.map((s) => s.text).join(' '),
        isNot(contains('Chapter 1')),
      );
      // The prose that follows is still narrated, in full.
      expect(aligned.sentences.first.text, startsWith('A new day begins'));
    });

    test('an <h1> title anywhere is skipped', () {
      const html = '<p>Opening line here.</p><h1>A Mid-book Heading</h1>'
          '<p>More prose after the heading.</p>';
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      final spoken = aligned.sentences.map((s) => s.text).join(' ');
      expect(spoken, isNot(contains('Mid-book Heading')));
      expect(spoken, contains('Opening line here'));
      expect(spoken, contains('More prose after the heading'));
    });

    test('a short unpunctuated line mid-chapter is still narrated', () {
      // Not a heading. A one-line aside or section divider in the middle of a
      // chapter is ordinary text, and swallowing it would silently drop prose.
      const html = '<p>He walked on in silence for a while.</p>'
          '<p>Not now</p>'
          '<p>He turned the corner and stopped.</p>';
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      final spoken = aligned.sentences.map((s) => s.text).join(' ');
      expect(spoken, contains('Not now'));
    });

    test('a first paragraph that is real prose is not treated as a title', () {
      const html = '<p>He opened the door and looked out at the rain.</p>';
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      // It has a full stop, so it is prose and must survive.
      expect(aligned.total, 1);
      expect(aligned.sentences.single.text, contains('looked out at the rain'));
    });

    test('a long first paragraph is never a title', () {
      final long = 'word ' * 60;
      final html = '<p>$long</p>';
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      expect(aligned.total, 1);
    });

    test('skipping a heading leaves indices contiguous', () {
      const html = '<p>Chapter 7</p><p>One here. Two here. Three here.</p>';
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      // A gap in the indices would make the engine's queue arithmetic wrong and
      // the highlight jump.
      expect(
        aligned.sentences.map((s) => s.index).toList(),
        List.generate(aligned.total, (i) => i),
      );
    });

    test('a chapter that is only a heading has nothing to read', () {
      const html = '<p>Chapter 1</p>';
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      expect(aligned.isEmpty, isTrue);
    });
  });

  group('alignment agrees with the speech-only path', () {
    test('the same chapter segments the same way on both paths', () {
      // The auto-advance path parses HTML per block; the reader path used to
      // parse the whole chapter, so the same chapter segmented differently
      // depending on how you arrived at it — and a resume index saved on one
      // path pointed at a different sentence on the other.
      const html = '<p>Chapter 1</p>'
          '<p>First sentence here. Second sentence here.</p>'
          '<p>Third sentence here.</p>';
      final layout = NovelTextLayout.fromHtml(html);
      final aligned = alignChapter(layout);

      // Compare the spoken text of the real blocks, heading aside.
      final spoken = aligned.sentences.map((s) => s.text).toList();
      expect(spoken, [
        'First sentence here.',
        'Second sentence here.',
        'Third sentence here.',
      ]);
    });

    test('both paths apply the narration filter', () {
      // The filter lives in the parser and in the two block loops, so it is easy
      // to wire it into the speech-only path and forget the reader. Then
      // narration that starts in the reader reads out an author's note, and the
      // same chapter counts differently depending on how it was reached — the
      // exact mismatch the test above was written to prevent.
      const html = '<h1>Chapter 4</h1>'
          "<p>Author's Note: hope you are well.</p>"
          '<p>The rain kept falling. Please support me on Patreon!</p>'
          '<p>Dawn came anyway.</p>';
      final spoken =
          alignChapter(NovelTextLayout.fromHtml(html)).sentences
              .map((s) => s.text)
              .toList();

      expect(spoken, [
        'The rain kept falling.',
        'Dawn came anyway.',
      ]);
    });

    test('a note block is skipped but the blocks around it keep their numbers', () {      // blockIndex is how the reader maps a sentence back to what it drew, so
      // dropping the note's sentences must not renumber the blocks after it.
      const html = '<h1>Chapter 5</h1>'
          '<p>One thing happened.</p>'
          "<p>Editor's Note: typo fixed.</p>"
          '<p>Two things happened.</p>';
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      final blocks = aligned.sentences.map((s) => s.blockIndex).toList();

      expect(aligned.sentences.map((s) => s.text).toList(), [
        'One thing happened.',
        'Two things happened.',
      ]);
      // Non-consecutive, because the note's block is still a block.
      expect(blocks.last, greaterThan(blocks.first));
    });

    test('skipping a sentence does not move the ones after it', () {
      // The property everything else rests on. A highlight is drawn by taking
      // startIndex..endIndex out of the text the reader rendered, so if
      // filtering shifted an offset by even one character, the highlight would
      // drift onto the wrong words — and it would drift silently, looking
      // almost right.
      const html = '<h1>Chapter 6</h1>'
          '<p>The first sentence is here. Please support me on Patreon!</p>'
          '<p>The third sentence is here.</p>';
      final layout = NovelTextLayout.fromHtml(html);
      final aligned = alignChapter(layout);

      for (final s in aligned.sentences) {
        expect(
          layout.text.substring(s.startIndex, s.endIndex).trim(),
          s.text,
          reason: 'offsets ${s.startIndex}..${s.endIndex} do not slice back '
              'to the sentence "${s.text}"',
        );
      }
      expect(aligned.sentences.map((s) => s.text).toList(), [
        'The first sentence is here.',
        'The third sentence is here.',
      ]);
    });
  });

  group('rangeAt', () {
    test('returns null outside the chapter', () {
      final aligned = alignChapter(NovelTextLayout.fromHtml('<p>One. Two.</p>'));
      expect(aligned.rangeAt(-1), isNull);
      expect(aligned.rangeAt(99), isNull);
      expect(aligned.rangeAt(0), isNotNull);
    });
  });

  group('highlightPages', () {
    final highlight = const TextStyle(backgroundColor: Color(0x44FFAA00));

    List<TextSpan> buildPages(String html, TextStyle base, Size size) {
      final spans = <InlineSpan>[];
      for (final t in tokenizeNovelHtml(html)) {
        if (t.isBreak) {
          spans.add(const TextSpan(text: '\n'));
          continue;
        }
        spans.add(
          TextSpan(
            text: t.text,
            style: base.copyWith(
              fontWeight: t.bold ? FontWeight.bold : null,
              fontStyle: t.italic ? FontStyle.italic : null,
            ),
          ),
        );
      }
      return paginateSpans(
        TextSpan(style: base, children: spans),
        pageSize: size,
        style: base,
      );
    }


    test('every sentence highlights on its own page across many pages', () {
      // Every other highlight test here uses a chapter that fits on ONE page.
      // A real chapter does not, and multi-page is the case that has to work:
      // the reader quotes a sentence, and the highlight has to be on those same
      // words somewhere later in the list of pages. The arithmetic that resolves
      // a chapter-wide offset to a page is only exercised when there is more than
      // one page to resolve it against.
      const base = TextStyle(fontSize: 14);
      final html = '<p>${List.generate(
            40,
            (i) => 'Sentence number $i runs on for a little while here.',
          ).join(' ')}</p>';

      final pages = buildPages(html, base, const Size(400, 240));
      expect(
        pages.length,
        greaterThan(3),
        reason: 'the chapter has to actually paginate for this to mean anything',
      );

      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      expect(aligned.total, greaterThan(8));

      // The two offset bases have to be the same string, or every range below is
      // measured against a different book.
      expect(
        pages.map((p) => p.toPlainText()).join(),
        aligned.layout.text,
        reason: 'page offsets and sentence offsets must share one basis',
      );

      for (var i = 0; i < aligned.total; i++) {
        final range = aligned.rangeAt(i)!;
        final page = pageIndexForRange(pages, range.start, range.end);
        expect(page, isNotNull, reason: 'sentence $i belongs to no page');

        final out = highlightPages(
          pages,
          range.start,
          range.end,
          highlight: highlight,
        );

        // Read across every page, not just the one the sentence starts on: a
        // sentence that straddles a page break is highlighted in two pieces, and
        // the page the reader is actually looking at may well be the second of
        // them. Collecting from one page would call correct behaviour broken.
        final painted = out
            .map(_highlightedText)
            .join()
            .trim();
        expect(
          painted,
          aligned.at(i)!.text,
          reason: 'sentence $i should highlight exactly its own words',
        );
        // And the page it starts on must actually be painted, or the reader is
        // looking at an unhighlighted page that claims to be the active one.
        expect(
          _highlightedText(out[page!]),
          isNotEmpty,
          reason: 'sentence $i starts on page $page, which is not highlighted',
        );
      }
    });

    test('a single-page chapter highlights the active sentence', () {
      const base = TextStyle(fontSize: 14);
      const html = '<p>First one here. Second one there.</p>';
      final pages = buildPages(html, base, const Size(400, 4000));
      expect(pages, hasLength(1));

      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      final range = aligned.rangeAt(1)!;
      final out = highlightPages(pages, range.start, range.end, highlight: highlight);

      // The text is unchanged: only decoration differs.
      expect(out.map((p) => p.toPlainText()).join(), pages.map((p) => p.toPlainText()).join());
      expect(_highlightedText(out.first), 'Second one there.');
    });

    test('highlighting the first sentence selects only the first', () {
      const base = TextStyle(fontSize: 14);
      const html = '<p>First one here. Second one there.</p>';
      final pages = buildPages(html, base, const Size(400, 4000));
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      final range = aligned.rangeAt(0)!;
      final out = highlightPages(pages, range.start, range.end, highlight: highlight);
      expect(_highlightedText(out.first), 'First one here.');
    });

    test('text outside the range is left unhighlighted', () {
      const base = TextStyle(fontSize: 14);
      const html = '<p>Alpha beta gamma. Delta epsilon zeta.</p>';
      final pages = buildPages(html, base, const Size(400, 4000));
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      final range = aligned.rangeAt(0)!;
      final out = highlightPages(pages, range.start, range.end, highlight: highlight);
      final highlighted = _highlightedText(out.first);
      expect(highlighted, 'Alpha beta gamma.');
      expect(highlighted, isNot(contains('Delta')));
    });

    test('an empty range is a no-op', () {
      const base = TextStyle(fontSize: 14);
      final pages = buildPages('<p>Some text here.</p>', base, const Size(400, 4000));
      final out = highlightPages(pages, 5, 5, highlight: highlight);
      expect(_highlightedText(out.first), isEmpty);
    });

    test('an inverted range is a no-op', () {
      const base = TextStyle(fontSize: 14);
      final pages = buildPages('<p>Some text here.</p>', base, const Size(400, 4000));
      final out = highlightPages(pages, 8, 3, highlight: highlight);
      expect(_highlightedText(out.first), isEmpty);
    });

    test('an out-of-range highlight does not throw', () {
      const base = TextStyle(fontSize: 14);
      final pages = buildPages('<p>Some text here.</p>', base, const Size(400, 4000));
      expect(
        () => highlightPages(pages, -50, 99999, highlight: highlight),
        returnsNormally,
      );
    });

    test('a multi-page chapter highlights only the page it lands on', () {
      const base = TextStyle(fontSize: 14);
      final html = '<p>${'Sentence number here. ' * 60}</p>';
      final pages = buildPages(html, base, const Size(320, 220));
      expect(pages.length, greaterThan(1), reason: 'test needs several pages');

      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      expect(aligned.total, greaterThan(10));

      // Highlight a sentence late in the chapter.
      final range = aligned.rangeAt(aligned.total - 2)!;
      final out = highlightPages(pages, range.start, range.end, highlight: highlight);

      final highlighted = out.map(_highlightedText).where((t) => t.isNotEmpty);
      expect(highlighted, hasLength(1), reason: 'exactly one page is affected');
      expect(
        highlighted.single.replaceAll(RegExp(r'\s+'), ' ').trim(),
        aligned.sentences[aligned.total - 2].text
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim(),
      );
    });

    test('bold text inside the range keeps its weight', () {
      const base = TextStyle(fontSize: 14);
      const html = '<p>He said <b>loudly</b> and stopped. Then silence.</p>';
      final pages = buildPages(html, base, const Size(400, 4000));
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      final range = aligned.rangeAt(0)!;
      final out = highlightPages(pages, range.start, range.end, highlight: highlight);

      // The bold run must stay bold *and* gain the background; losing either
      // is a visible regression in how the chapter reads.
      final boldHighlighted = _boldHighlightedText(out.first);
      expect(boldHighlighted, 'loudly');
    });

    test('highlighting never changes the page text', () {
      const base = TextStyle(fontSize: 14);
      const html = '<p>One sentence here. Another sentence here. A third.</p>';
      final pages = buildPages(html, base, const Size(300, 200));
      final aligned = alignChapter(NovelTextLayout.fromHtml(html));
      for (var i = 0; i < aligned.total; i++) {
        final r = aligned.rangeAt(i)!;
        final out = highlightPages(pages, r.start, r.end, highlight: highlight);
        expect(
          out.map((p) => p.toPlainText()).join(),
          pages.map((p) => p.toPlainText()).join(),
          reason: 'highlighting sentence $i altered the text',
        );
      }
    });
  });
}

/// Which page an offset falls on, derived independently of
/// [pageIndexForRange].
///
/// Computed straight from the concatenated page text rather than by calling the
/// function under test, so the two are genuinely independent and a shared bug
/// cannot make the assertion vacuous.
int _expectedPage(List<TextSpan> pages, String chapterText, int offset) {
  final full = pages.map((p) => p.toPlainText()).join();
  expect(full.length, chapterText.length, reason: 'pages must cover the text');
  var start = 0;
  for (var i = 0; i < pages.length; i++) {
    final end = start + pages[i].toPlainText().length;
    if (offset >= start && offset < end) return i;
    start = end;
  }
  return -1;
}

/// The characters painted with the highlight style, in order.
///
/// Walks the span tree and collects only the text whose resolved style carries
/// the highlight background, which is what "what is highlighted" actually means.
String _highlightedText(InlineSpan span, {bool boldOnly = false}) {
  final buffer = StringBuffer();
  _walk(span, buffer, boldOnly: boldOnly, inheritedBold: false);
  return buffer.toString();
}

String _boldHighlightedText(InlineSpan span) =>
    _highlightedText(span, boldOnly: true);

const _hl = Color(0x44FFAA00);

void _walk(
  InlineSpan span,
  StringBuffer out, {
  required bool boldOnly,
  required bool inheritedBold,
}) {
  if (span is! TextSpan) return;
  final bold = inheritedBold || span.style?.fontWeight == FontWeight.bold;
  final highlighted = span.style?.backgroundColor == _hl;
  final take = boldOnly ? (bold && highlighted) : highlighted;
  if (take && span.text != null) out.write(span.text);
  final children = span.children;
  if (children != null) {
    for (final child in children) {
      _walk(child, out, boldOnly: boldOnly, inheritedBold: bold);
    }
  }
}

