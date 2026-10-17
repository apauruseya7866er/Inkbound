import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/reader/novel_html.dart';
import 'package:watch_app/features/reader/tts_alignment.dart';
import 'package:watch_app/features/reader/tts_highlight_box.dart';

TextSpan _span(String text, {double size = 14, Color? colour}) =>
    TextSpan(text: text, style: TextStyle(fontSize: size, color: colour));

/// Every distinct colour a span tree resolves to, in the order first seen.
///
/// Resolves each span against its ancestors, because the highlight merges into
/// the existing style rather than replacing it - so the colour of a leaf is the
/// merge of every style above it, not the last one written.
List<Color> _coloursIn(InlineSpan span, [TextStyle? inherited]) {
  final found = <Color>[];
  void walk(InlineSpan node, TextStyle base) {
    // Only TextSpan has text and children; a WidgetSpan has neither and
    // contributes nothing to resolve.
    if (node is! TextSpan) return;
    final style = base.merge(node.style);
    if (node.text != null && node.text!.isNotEmpty) {
      final c = style.color;
      if (c != null && !found.contains(c)) found.add(c);
    }
    for (final child in node.children ?? const <InlineSpan>[]) {
      walk(child, style);
    }
  }

  walk(span, inherited ?? const TextStyle());
  return found;
}

/// WCAG contrast ratio between two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

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
      final expected =
          painter.getBoxesForSelection(const TextSelection(baseOffset: 3, extentOffset: 14));
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

      // Stacked, not overlapping: a box per line is what gets unioned into the
      // single outline around the phrase.
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

  group('the text palette', () {
    test('ids are unique', () {
      final ids = ttsHighlightTextPalette.map((c) => c.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('the default leaves the text alone', () {
      final def = ttsHighlightTextChoiceFor(kDefaultTtsHighlightTextId);
      expect(def.color, isNull);
      expect(def.label, 'Default');
    });

    test('only the default has no colour', () {
      for (final choice in ttsHighlightTextPalette) {
        if (choice.id == kDefaultTtsHighlightTextId) continue;
        expect(choice.color, isNotNull, reason: choice.id);
      }
    });

    test('every ink colour is readable on a near-black page', () {
      // Why there is no black here: this text sits inside the wash on a page the
      // reader picks, and the dark themes are near-black. A colour that cannot
      // carry glyphs against those is a broken option, not a style.
      const page = Color(0xFF0B0B0F);
      for (final choice in ttsHighlightTextPalette) {
        final colour = choice.color;
        if (colour == null) continue;
        // 4.5:1 is the WCAG AA threshold for body text.
        expect(
          _contrast(colour, page),
          greaterThanOrEqualTo(4.5),
          reason: '${choice.label} text is unreadable on a black page',
        );
      }
    });

    test('text inks are lighter than the same-hue wash, so they carry glyphs', () {
      for (final wash in ttsHighlightPalette) {
        final ink = ttsHighlightTextChoiceFor(wash.id).color;
        if (ink == null) continue;
        expect(
          ink.computeLuminance(),
          greaterThan(wash.color.computeLuminance()),
          reason: '${wash.label} wash and ink are the same brightness',
        );
      }
    });

    test('an unknown id falls back to the default', () {
      expect(
        ttsHighlightTextChoiceFor('chartreuse').id,
        kDefaultTtsHighlightTextId,
      );
      expect(
        ttsHighlightTextChoiceFor(null).id,
        kDefaultTtsHighlightTextId,
      );
    });
  });

  group('recolouring the highlighted range', () {
    Widget wrap(Widget child) => MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 300, child: child),
          ),
        );

    const text = 'One two three four five six seven eight.';

    /// The rendered span, so the assertion is about what the text engine was
    /// actually handed rather than about the widget's own field.
    InlineSpan rendered(WidgetTester tester) => tester
        .widget<RichText>(
          find.descendant(
            of: find.byType(TtsHighlightText),
            matching: find.byType(RichText),
          ),
        )
        .text;

    testWidgets('a chosen ink recolours only the highlighted words', (
      tester,
    ) async {
      // The whole point of the setting: the sentence stands out by its colour,
      // not only by the wash behind it.
      await tester.pumpWidget(
        wrap(TtsHighlightText(
          span: _span(text),
          textAlign: TextAlign.start,
          pageBackground: const Color(0xFF0B0B0F),
          choice: ttsHighlightChoiceFor('blue'),
          textChoice: ttsHighlightTextChoiceFor('amber'),
          rangeStart: 4,
          rangeEnd: 8, // "two"
        )),
      );
      await tester.pump();

      final span = rendered(tester);
      expect(span.toPlainText(), text, reason: 'the words survive');
      expect(
        _coloursIn(span),
        contains(ttsHighlightTextChoiceFor('amber').color),
      );
    });

    testWidgets('words outside the range keep their original colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(TtsHighlightText(
          span: _span(text, colour: const Color(0xFF123456)),
          textAlign: TextAlign.start,
          pageBackground: const Color(0xFF0B0B0F),
          choice: ttsHighlightChoiceFor('blue'),
          textChoice: ttsHighlightTextChoiceFor('amber'),
          rangeStart: 4,
          rangeEnd: 8,
        )),
      );
      await tester.pump();

      // Both colours present: the ink inside the range, the page's own outside.
      final colours = _coloursIn(rendered(tester));
      expect(colours, contains(const Color(0xFF123456)));
      expect(colours, contains(ttsHighlightTextChoiceFor('amber').color));
    });

    testWidgets('the default ink leaves the original span untouched', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(TtsHighlightText(
          span: _span(text, colour: const Color(0xFF123456)),
          textAlign: TextAlign.start,
          pageBackground: const Color(0xFF0B0B0F),
          choice: ttsHighlightChoiceFor('blue'),
          textChoice: ttsHighlightTextChoiceFor('default'),
          rangeStart: 4,
          rangeEnd: 8,
        )),
      );
      await tester.pump();

      // Only one colour in the tree, so nothing was recoloured.
      expect(_coloursIn(rendered(tester)), const [Color(0xFF123456)]);
    });

    testWidgets('a wash still paints even with no ink chosen', (tester) async {
      await tester.pumpWidget(
        wrap(TtsHighlightText(
          span: _span(text),
          textAlign: TextAlign.start,
          pageBackground: const Color(0xFF0B0B0F),
          choice: ttsHighlightChoiceFor('purple'),
          rangeStart: 0,
          rangeEnd: text.length,
        )),
      );
      await tester.pump();

      final painter = tester
          .widget<CustomPaint>(
            find.descendant(
              of: find.byType(TtsHighlightText),
              matching: find.byType(CustomPaint),
            ),
          )
          .painter;
      expect(painter, isNotNull, reason: 'the wash is independent of the ink');
    });
  });

  group('ttsHighlightLineRects', () {
    // The exact boxes a real device produced for a sentence wrapping over three
    // lines. Note the first line is indented (79..286) while the other two run
    // the full measure (0..320): that asymmetry is what the old painter made
    // worse by unioning them, since a single box spanning all three left a wide
    // empty margin beside the short first line.
    final wrapped = <Rect>[
      const Rect.fromLTRB(79, 96, 286, 114),
      const Rect.fromLTRB(0, 119, 320, 137),
      const Rect.fromLTRB(0, 142, 266, 160),
    ];

    test('keeps one box per line instead of one around the sentence', () {
      expect(ttsHighlightLineRects(wrapped), hasLength(3));
    });

    test('each box hugs its own line, not the widest one', () {
      final rects = ttsHighlightLineRects(wrapped);
      // The short first line must not be stretched out to the width of the
      // full-measure second line - that is the whole point of per line.
      expect(rects[0].right, lessThan(rects[1].right));
      expect(rects[2].right, lessThan(rects[1].right));
      // And they must not all start at the same left edge either.
      expect(rects[0].left, greaterThan(rects[1].left));
    });

    test('pads every box outward by the mark inset', () {
      final rects = ttsHighlightLineRects(wrapped);
      expect(
        rects[0],
        const Rect.fromLTRB(
          79 - TtsHighlightText.padHorizontal,
          96 - TtsHighlightText.padVertical,
          286 + TtsHighlightText.padHorizontal,
          114 + TtsHighlightText.padVertical,
        ),
      );
    });

    test('does not mutate the boxes it was given', () {
      final input = [...wrapped];
      ttsHighlightLineRects(input);
      expect(input, wrapped);
    });

    test('drops the zero-width box the engine reports at a line break', () {
      // Padding a degenerate box would draw a lone vertical sliver at the right
      // margin, which reads as a stray mark rather than part of the sentence.
      final rects = ttsHighlightLineRects([
        const Rect.fromLTRB(10, 20, 110, 40),
        const Rect.fromLTRB(110, 40, 110, 40),
      ]);
      expect(rects, hasLength(1));
      expect(rects.single, const Rect.fromLTRB(4, 17, 116, 43));
    });

    test('is empty for no boxes', () {
      expect(ttsHighlightLineRects(const []), isEmpty);
    });
  });

  group('the palette', () {
    test('ids are unique, or one colour would shadow another', () {
      final ids = ttsHighlightPalette.map((c) => c.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('every colour is visible against a black page', () {
      // The regression this guards: one shared alpha cannot serve a list this
      // varied. Blue and coral at the same strength composite to very different
      // things over near-black, and at a low shared alpha the dim ones vanish.
      const page = Color(0xFF0B0B0F);
      for (final choice in ttsHighlightPalette) {
        final wash = TtsHighlightText.tintFor(page, choice);
        // Compare the composite against the page, not the raw alpha: what the
        // reader sees is the wash laid over black.
        final composited = Color.lerp(page, wash, wash.a)!;
        expect(
          (composited.computeLuminance() - page.computeLuminance()).abs(),
          greaterThan(0.01),
          reason: '${choice.label} is invisible on a black page',
        );
      }
    });

    test('every colour is visible on a light page too', () {
      // Not "light is always stronger": that is not a real rule. A saturated
      // colour contrasts easily against cream, so blue needs LESS on paper
      // (0.24) than on black (0.30), while a pale one like white needs more. The
      // guarantee worth pinning is that every colour reads on every page, which
      // is exactly what per-colour alphas are for.
      const page = Color(0xFFFAF6EE);
      for (final choice in ttsHighlightPalette) {
        final wash = TtsHighlightText.tintFor(page, choice);
        final composited = Color.lerp(page, wash, wash.a)!;
        expect(
          (composited.computeLuminance() - page.computeLuminance()).abs(),
          greaterThan(0.01),
          reason: '${choice.label} is invisible on a light page',
        );
      }
    });

    test('the default is a colour that exists in the palette', () {
      expect(
        ttsHighlightPalette.any((c) => c.id == kDefaultTtsHighlightId),
        isTrue,
      );
    });

    test('an unknown id falls back to the default rather than failing', () {
      expect(ttsHighlightChoiceFor('chartreuse').id, kDefaultTtsHighlightId);
      expect(ttsHighlightChoiceFor(null).id, kDefaultTtsHighlightId);
      expect(ttsHighlightChoiceFor('').id, kDefaultTtsHighlightId);
    });
  });

  group('the tint follows the page and the colour', () {
    // The reader's real page backgrounds, so the rule is asserted against the
    // colours it will actually meet.
    test('a dark page uses the dark wash for the chosen colour', () {
      for (final page in const [
        Color(0xFF0B0B0F), // dark
        Color(0xFF000000), // black
        Color(0xFF2B2B2E), // gray
      ]) {
        final blue = ttsHighlightChoiceFor('blue');
        expect(
          TtsHighlightText.tintFor(page, blue).a,
          closeTo(blue.darkAlpha, 0.01),
          reason: '$page is a dark page',
        );
      }
    });

    test('sepia and paper use the light wash instead', () {
      for (final page in const [
        Color(0xFFF0E6D2), // sepia
        Color(0xFFFAF6EE), // paper
      ]) {
        for (final choice in ttsHighlightPalette) {
          expect(
            TtsHighlightText.tintFor(page, choice).a,
            closeTo(choice.lightAlpha, 0.01),
            reason: '${choice.label} on $page',
          );
        }
      }
    });

    test('the wash carries the chosen colour, not a fixed one', () {
      const noAlpha = 0x00FFFFFF;
      for (final choice in ttsHighlightPalette) {
        expect(
          TtsHighlightText.tintFor(const Color(0xFF0B0B0F), choice)
              .toARGB32() &
              noAlpha,
          choice.color.toARGB32() & noAlpha,
        );
      }
    });
  });

  group('TtsHighlightText', () {
    Widget wrap(Widget child) => MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 300, child: child),
          ),
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
        wrap(TtsHighlightText(
          span: _span('A sentence to be marked, and more text after it.'),
          textAlign: TextAlign.start,
          pageBackground: const Color(0xFF0B0B0F),
          choice: ttsHighlightChoiceFor('blue'),
        )),
      );
      expect(painterUnderTest(), isNull);

      await tester.pumpWidget(
        wrap(TtsHighlightText(
          span: _span('A sentence to be marked, and more text after it.'),
          textAlign: TextAlign.start,
          pageBackground: const Color(0xFF0B0B0F),
          choice: ttsHighlightChoiceFor('blue'),
          rangeStart: 2,
          rangeEnd: 10,
        )),
      );
      expect(painterUnderTest(), isNotNull);
    });

    testWidgets('still renders the text itself', (tester) async {
      const text = 'The words have to survive the decoration.';
      await tester.pumpWidget(
        wrap(TtsHighlightText(
          span: _span(text),
          textAlign: TextAlign.start,
          pageBackground: const Color(0xFF0B0B0F),
          choice: ttsHighlightChoiceFor('blue'),
          rangeStart: 4,
          rangeEnd: 9,
        )),
      );
      expect(find.textContaining(text, findRichText: true), findsOneWidget);
    });
  });

  group('range helpers', () {
    const html = '<p>First block of the chapter.</p>'
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
