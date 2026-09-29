import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/reader/novel_html.dart';
import 'package:watch_app/features/reader/tts_alignment.dart';

/// Every block's rendered plain text, joined with a newline.
String blockText(NovelTextLayout layout) => layout.blocks
    .map(
      (b) => novelBlockSpans(layout, b.index, base: const TextStyle())
          .map((s) => s.toPlainText())
          .join(),
    )
    .join('\n');

String highlighted(NovelTextLayout layout, int block, int start, int end) {
  final style = const TextStyle(backgroundColor: Color(0x44FFAA00));
  return novelBlockSpans(
    layout,
    block,
    base: const TextStyle(),
    highlightStart: start,
    highlightEnd: end,
    highlight: style,
  ).map((s) => s.toPlainText()).join();
}

String paintedIn(
  NovelTextLayout layout,
  int block,
  int start,
  int end,
) =>
    novelBlockSpans(
      layout,
      block,
      base: const TextStyle(),
      highlightStart: start,
      highlightEnd: end,
      highlight: const TextStyle(backgroundColor: Color(0x44FFAA00)),
    ).map(_backgroundText).join();

/// Plain text of the runs carrying the highlight background, in order.
String _backgroundText(InlineSpan span) {
  final buffer = StringBuffer();
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      if (s.text != null &&
          s.style?.backgroundColor ==
              const Color(0x44FFAA00)) {
        buffer.write(s.text);
      }
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c);
      }
    }
  }

  walk(span);
  return buffer.toString();
}

void main() {
  const base = TextStyle(fontSize: 14);

  group('scroll-mode block spans', () {
    test('every block renders exactly its slice of the layout text', () {
      // The invariant everything rests on. If a block's spans do not reproduce
      // its own range of the layout text, every offset into that block is wrong
      // and the highlight lands on the wrong words.
      const html = '<h1>Chapter 1: Begins</h1>'
          '<p>First paragraph here. And more of it.</p>'
          '<p>Roses are red<br>Violets are blue</p>'
          '<p><b>Bolded</b> then plain. <i>Italic</i> too.</p>';

      final layout = NovelTextLayout.fromHtml(html);
      for (final b in layout.blocks) {
        final rendered = novelBlockSpans(layout, b.index, base: base)
            .map((s) => s.toPlainText())
            .join();
        expect(
          rendered,
          layout.text.substring(b.start, b.end),
          reason: 'block ${b.index} does not match its layout range',
        );
      }
    });

    test('a soft line break stays inside its paragraph', () {
      const html = '<p>Roses are red<br>Violets are blue</p>';
      final layout = NovelTextLayout.fromHtml(html);
      expect(layout.blocks, hasLength(1));
      expect(
        novelBlockSpans(layout, 0, base: base)
            .map((s) => s.toPlainText())
            .join(),
        'Roses are red\nViolets are blue',
      );
    });

    test('bold and italic survive into the block', () {
      const html = '<p><b>Bolded</b> then plain. <i>Italic</i> too.</p>';
      final layout = NovelTextLayout.fromHtml(html);
      final spans = novelBlockSpans(layout, 0, base: base);
      final bolded = spans.whereType<TextSpan>().where(
            (s) => s.style?.fontWeight == FontWeight.bold,
          );
      expect(bolded.map((s) => s.text).join(), 'Bolded');
      final italics = spans.whereType<TextSpan>().where(
            (s) => s.style?.fontStyle == FontStyle.italic,
          );
      expect(italics.map((s) => s.text).join(), 'Italic');
    });

    test('entities are rendered as their characters', () {
      const html = '<p>Tom &amp; Jerry said &quot;hi&quot;.</p>';
      final layout = NovelTextLayout.fromHtml(html);
      // The layout text carries the paragraph break's own newline after the
      // prose; the block itself is only the prose.
      expect(layout.text, 'Tom & Jerry said "hi".\n');
      expect(
        novelBlockSpans(layout, 0, base: base)
            .map((s) => s.toPlainText())
            .join(),
        'Tom & Jerry said "hi".',
      );
    });

    test('an out-of-range block is empty rather than a crash', () {
      final layout = NovelTextLayout.fromHtml('<p>One.</p>');
      expect(novelBlockSpans(layout, 99, base: base), isEmpty);
      expect(novelBlockSpans(layout, -1, base: base), isEmpty);
    });
  });

  group('scroll-mode highlight', () {
    test('highlights exactly the active sentence, in the right block', () {
      const html = '<p>Alpha one here. Beta two here. Gamma three here.</p>'
          '<p>Delta four here. Epsilon five here.</p>';
      final layout = NovelTextLayout.fromHtml(html);
      final aligned = alignChapter(layout);

      for (var i = 0; i < aligned.total; i++) {
        final sentence = aligned.at(i)!;
        final block =
            blockIndexForOffset(layout, sentence.startIndex)!;
        expect(
          paintedIn(layout, block, sentence.startIndex, sentence.endIndex),
          sentence.text,
          reason: 'sentence $i should be the only highlighted run in its block',
        );
      }
    });

    test('a sentence inside styled runs highlights across them', () {
      // The case a whole-paragraph CSS class cannot do: the sentence starts in
      // plain text, runs through <b>, and ends in plain text again.
      const html = '<p>He said <b>loudly</b> and then he left the room.</p>';
      final layout = NovelTextLayout.fromHtml(html);
      final aligned = alignChapter(layout);
      final sentence = aligned.at(0)!;

      expect(
        paintedIn(
          layout,
          blockIndexForOffset(layout, sentence.startIndex)!,
          sentence.startIndex,
          sentence.endIndex,
        ),
        sentence.text,
      );
    });

    test('a range that spills into the next block is clipped to this one', () {
      const html = '<p>One two three.</p><p>Four five six.</p>';
      final layout = NovelTextLayout.fromHtml(html);
      // A deliberately over-long range: the tail of block 0 plus the head of
      // block 1. Each block must paint only its own share, and between them they
      // must cover the range exactly once — no duplicated and no missing
      // characters, which is what a naive unclipped decorator would do.
      final from = layout.blocks[0].end - 3; // "ee."
      final to = layout.blocks[1].start + 3; // "Fou"
      expect(paintedIn(layout, 0, from, to), 'ee.');
      expect(paintedIn(layout, 1, from, to), 'Fou');
      expect(paintedIn(layout, 0, from, to) + paintedIn(layout, 1, from, to),
          'ee.Fou');
    });

    test('no highlight leaves the text untouched', () {
      const html = '<p>Plain text here.</p>';
      final layout = NovelTextLayout.fromHtml(html);
      expect(highlighted(layout, 0, 0, 0), 'Plain text here.');
      expect(
        novelBlockSpans(layout, 0, base: base, highlightStart: 0, highlightEnd: 5)
            .map((s) => s.toPlainText())
            .join(),
        'Plain text here.',
      );
    });
  });

  group('block offsets for following the sentence', () {
    const style = TextStyle(fontSize: 14);
    const width = 360.0;

    List<double> measure(NovelTextLayout layout, {double spacing = 0}) =>
        measureBlockOffsets(
          layout,
          style: style,
          width: width,
          paragraphSpacing: spacing,
          textDirection: TextDirection.ltr,
        );

    test('one entry per block, plus a total', () {
      final layout = NovelTextLayout.fromHtml(
        '<p>One.</p><p>Two.</p><p>Three.</p><p>Four.</p>',
      );
      final offsets = measure(layout);
      expect(offsets, hasLength(layout.blocks.length + 1));
      expect(offsets.first, 0);
      // Strictly increasing: a follow that lands on the same y as the previous
      // block cannot tell them apart.
      for (var i = 1; i < offsets.length; i++) {
        expect(offsets[i], greaterThan(offsets[i - 1]));
      }
    });

    test('paragraph spacing widens the gap between blocks', () {
      final layout = NovelTextLayout.fromHtml(
        '<p>One paragraph of a reasonable length here.</p>'
        '<p>Another paragraph of a reasonable length here.</p>',
      );
      final tight = measure(layout);
      final loose = measure(layout, spacing: 20);
      // Same text, so block heights are unchanged; only the gaps differ.
      expect(
        loose.last - tight.last,
        closeTo(20 * layout.blocks.length, 0.5),
      );
    });

    test('every block is reachable, including one far off screen', () {
      // The point: a SliverList never builds a block that is off screen, so the
      // follow has to reach it by arithmetic instead.
      final html = List.generate(
        30,
        (i) => '<p>Paragraph $i with enough words to occupy a line or two '
            'of a phone screen at this size.</p>',
      ).join();
      final layout = NovelTextLayout.fromHtml(html);
      final offsets = measure(layout);
      expect(layout.blocks.length, 30);
      expect(offsets, hasLength(31));

      for (var i = 0; i < 30; i++) {
        expect(offsets[i + 1], greaterThan(offsets[i]));
      }
      expect(offsets[29], lessThan(offsets[30]));
    });

    test('an empty chapter measures to nothing rather than throwing', () {
      final layout = NovelTextLayout.fromHtml('');
      expect(measure(layout), [0.0]);
    });

    test('a single long block is one entry', () {
      final layout = NovelTextLayout.fromHtml('<p>${'word ' * 200}</p>');
      final offsets = measure(layout);
      expect(offsets, hasLength(2));
      expect(offsets[1], greaterThan(0));
    });
  });

  group('blockIndexForOffset', () {
    test('finds the containing block', () {
      const html = '<p>First block here.</p><p>Second block here.</p>';
      final layout = NovelTextLayout.fromHtml(html);
      expect(blockIndexForOffset(layout, 0), 0);
      expect(blockIndexForOffset(layout, layout.blocks[1].start), 1);
      expect(blockIndexForOffset(layout, -1), isNull);
      expect(blockIndexForOffset(layout, layout.length), isNull);
    });
  });

  group('scroll-mode highlight', () {
    test('a realistic chapter highlights the right words in every block', () {
      final html = '<h1>Chapter 4</h1>' + List.generate(
            8,
            (i) => '<p>Paragraph $i opens here. It goes on a little.</p>',
          ).join();
      final layout = NovelTextLayout.fromHtml(html);
      final aligned = alignChapter(layout);

      // Every sentence lands in exactly one block and paints exactly itself.
      for (var i = 0; i < aligned.total; i++) {
        final s = aligned.at(i)!;
        final block = blockIndexForOffset(layout, s.startIndex);
        expect(block, isNotNull);
        expect(paintedIn(layout, block!, s.startIndex, s.endIndex), s.text);
      }
    });
  });
}
