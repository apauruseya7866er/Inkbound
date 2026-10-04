import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/reader/novel_html.dart';
import 'package:watch_app/features/reader/tts_alignment.dart';
import 'package:watch_app/features/reader/tts_highlight_box.dart';

TextSpan _span(String text, {double size = 14}) => TextSpan(
  text: text,
  style: TextStyle(fontSize: size),
);

void main() {
  group('ttsHighlightBoxes', () {
    test('covers the words of a single-line range', () {
      const text = 'He walked into the room and looked around.';
      final boxes = ttsHighlightBoxes(
        span: _span(text),
        start: 3,
        end: 14, // "walked into"
        maxWidth: 400,
        textDirection: TextDirection.ltr,
      );
      expect(boxes, hasLength(1));

      // The box has to sit on the words it marks, so compare it with the
      // engine's own metrics for the same range rather than with a magic number.
      final painter = TextPainter(
        text: _span(text),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 400);
      final expected = painter.getBoxesForSelection(
        const TextSelection(baseOffset: 3, extentOffset: 14),
      );
      painter.dispose();

      expect(boxes.single.left, closeTo(expected.first.left, 0.01));
      expect(boxes.single.right, closeTo(expected.first.right, 0.01));
      expect(boxes.single.top, closeTo(expected.first.top, 0.01));
    });

    test('returns one box per line for a range that wraps', () {
      const text =
          'The first clause of this sentence is long enough to wrap onto a '
          'second line, and the rest of it carries on past that.';
      final boxes = ttsHighlightBoxes(
        span: _span(text),
        start: 0,
        end: text.length,
        maxWidth: 120,
        textDirection: TextDirection.ltr,
      );
      expect(boxes.length, greaterThan(1));

      // Stacked, not overlapping: the painter applies a separate soft fill to
      // each line touched by the phrase.
      for (var i = 1; i < boxes.length; i++) {
        expect(boxes[i].top, greaterThanOrEqualTo(boxes[i - 1].bottom - 0.01));
      }
    });

    test('ignores a missing, empty or inverted range', () {
      final boxes = ttsHighlightBoxes(
        span: _span('Some text here.'),
        start: null,
        end: 4,
        maxWidth: 400,
        textDirection: TextDirection.ltr,
      );
      expect(boxes, isEmpty);

      expect(
        ttsHighlightBoxes(
          span: _span('Some text here.'),
          start: 4,
          end: 4,
          maxWidth: 400,
          textDirection: TextDirection.ltr,
        ),
        isEmpty,
      );
      expect(
        ttsHighlightBoxes(
          span: _span('Some text here.'),
          start: 9,
          end: 2,
          maxWidth: 400,
          textDirection: TextDirection.ltr,
        ),
        isEmpty,
      );
    });

    test('clamps a range that runs off the end, rather than dropping it', () {
      // A sentence that continues overleaf hands this widget a range past the
      // end of the text it is drawing; the visible part still gets a box.
      const text = 'A sentence that continues';
      final boxes = ttsHighlightBoxes(
        span: _span(text),
        start: 2,
        end: text.length + 500,
        maxWidth: 400,
        textDirection: TextDirection.ltr,
      );
      expect(boxes, hasLength(1));
      expect(boxes.single.right, greaterThan(0));
    });

    test('handles an empty span', () {
      expect(
        ttsHighlightBoxes(
          span: _span(''),
          start: 0,
          end: 5,
          maxWidth: 400,
          textDirection: TextDirection.ltr,
        ),
        isEmpty,
      );
    });
  });

  group('ttsHighlightRect', () {
    // The exact boxes a real device produced for a sentence wrapping over three
    // lines. Regression fixture for the union helper retained for geometry
    // assertions; the painter now fills individual lines.
    final wrapped = <Rect>[
      const Rect.fromLTRB(79, 96, 286, 114),
      const Rect.fromLTRB(0, 119, 320, 137),
      const Rect.fromLTRB(0, 142, 266, 160),
    ];

    test('encloses every line of a wrapped range', () {
      final rect = ttsHighlightRect(wrapped)!;
      expect(rect.top, lessThanOrEqualTo(96));
      expect(rect.bottom, greaterThanOrEqualTo(160));
      expect(rect.left, lessThanOrEqualTo(0));
      expect(rect.right, greaterThanOrEqualTo(320));
    });

    test('does not mutate the boxes it was given', () {
      final input = [...wrapped];
      ttsHighlightRect(input);
      expect(input, wrapped);
    });

    test('is the first box, padded, for a single-line range', () {
      final rect = ttsHighlightRect([const Rect.fromLTRB(10, 20, 110, 40)])!;
      expect(
        rect,
        const Rect.fromLTRB(
          10 - TtsHighlightText.padHorizontal,
          20 - TtsHighlightText.padVertical,
          110 + TtsHighlightText.padHorizontal,
          40 + TtsHighlightText.padVertical,
        ),
      );
    });

    test('is null for no boxes', () {
      expect(ttsHighlightRect(const []), isNull);
    });
  });

  group('TtsHighlightText', () {
    Widget wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SizedBox(width: 300, child: child)),
    );

    testWidgets('paints a box only when a range is given', (tester) async {
      // Scoped to the widget: MaterialApp and Scaffold bring their own
      // CustomPaint widgets along.
      CustomPainter? painterUnderTest() => tester
          .widget<CustomPaint>(
            find.descendant(
              of: find.byType(TtsHighlightText),
              matching: find.byType(CustomPaint),
            ),
          )
          .painter;

      await tester.pumpWidget(
        wrap(
          TtsHighlightText(
            span: _span('A sentence to be marked, and more text after it.'),
            textAlign: TextAlign.start,
          ),
        ),
      );
      expect(painterUnderTest(), isNull);

      await tester.pumpWidget(
        wrap(
          TtsHighlightText(
            span: _span('A sentence to be marked, and more text after it.'),
            textAlign: TextAlign.start,
            rangeStart: 2,
            rangeEnd: 10,
          ),
        ),
      );
      expect(painterUnderTest(), isNotNull);
    });

    testWidgets('still renders the text itself', (tester) async {
      const text = 'The words have to survive the decoration.';
      await tester.pumpWidget(
        wrap(
          TtsHighlightText(
            span: _span(text),
            textAlign: TextAlign.start,
            rangeStart: 4,
            rangeEnd: 9,
          ),
        ),
      );
      expect(find.textContaining(text, findRichText: true), findsOneWidget);
    });

    testWidgets(
      'uses a soft lavender fill and dark text for the active range',
      (tester) async {
        const text = 'A sentence to highlight, and more text after it.';
        await tester.pumpWidget(
          wrap(
            TtsHighlightText(
              span: _span(text),
              textAlign: TextAlign.start,
              rangeStart: 2,
              rangeEnd: 10,
            ),
          ),
        );
        final richText = tester.widget<RichText>(find.byType(RichText));
        expect(richText.text.toPlainText(), text);
        expect(TtsHighlightText.fillColor, const Color(0xFFDDE1FC));
        expect(TtsHighlightText.textColor, const Color(0xFF292A45));

        final highlighted = <TextSpan>[];
        void visit(InlineSpan span) {
          if (span is! TextSpan) return;
          if (span.style?.color == TtsHighlightText.textColor) {
            highlighted.add(span);
          }
          span.children?.forEach(visit);
        }

        visit(richText.text);
        expect(highlighted, hasLength(1));
        expect(highlighted.single.toPlainText(), 'sentence');
      },
    );
  });

  group('range helpers', () {
    const html =
        '<p>First block of the chapter.</p>'
        '<p>Second block here, with more words in it.</p>'
        '<p>Third and last block.</p>';

    test('blockSliceFor rebases a chapter range onto its block', () {
      final layout = NovelTextLayout.fromHtml(html);
      final block = layout.blocks[1];
      final slice = blockSliceFor(layout, 1, block.start + 3, block.start + 9);
      expect(slice, isNotNull);
      expect(slice!.from, 3);
      expect(slice.to, 9);
    });

    test('blockSliceFor clips a range that runs past the block', () {
      final layout = NovelTextLayout.fromHtml(html);
      final block = layout.blocks[0];
      final slice = blockSliceFor(layout, 0, block.start, block.end + 100);
      expect(slice!.to, block.end - block.start);
    });

    test('blockSliceFor returns null when the range misses the block', () {
      final layout = NovelTextLayout.fromHtml(html);
      final block = layout.blocks[0];
      expect(blockSliceFor(layout, 2, block.start, block.end), isNull);
      expect(blockSliceFor(layout, 1, 5, 5), isNull);
      expect(blockSliceFor(layout, 99, 0, 4), isNull);
    });

    test('pageSliceFor rebases a chapter range onto its page', () {
      final pages = <TextSpan>[
        _span('Page zero words.'),
        _span('Page one words, and then some more of them.'),
      ];
      const start = 16; // first character of page one
      final slice = pageSliceFor(pages, 1, start + 5, start + 10);
      expect(slice!.from, 5);
      expect(slice.to, 10);
    });

    test('pageSliceFor returns null for a page the range is not on', () {
      final pages = <TextSpan>[_span('Page zero words.'), _span('Page one.')];
      expect(pageSliceFor(pages, 0, 20, 24), isNull);
      expect(pageSliceFor(pages, 5, 0, 4), isNull);
      expect(pageSliceFor(pages, 0, 3, 3), isNull);
    });
  });
}
