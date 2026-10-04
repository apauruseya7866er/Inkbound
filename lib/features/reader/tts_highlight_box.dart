import 'package:flutter/material.dart';

/// The read-aloud highlight: a soft blue box with a blue outline around the
/// sentence being spoken.
///
/// ### Why this is painted rather than styled
///
/// `TextStyle.background` cannot draw a border, and a border is the part that
/// makes the highlight read as a deliberate marker instead of a smudge of
/// colour behind the words — especially on the light page themes, where a tint
/// alone disappears into the paper. `TextStyle` has no border primitive at all,
/// so the box has to be painted.
///
/// ### Why it cannot drift out of line with the text
///
/// The rectangles come from a [TextPainter] laid out with the *same* span, width,
/// alignment, direction and text scaler as the [Text.rich] underneath it, and
/// the painter is the parent of that text, so both share one origin. A box
/// positioned from anything else — a measured line height, an assumed character
/// width — lands a few pixels off the words it is meant to be marking, which
/// looks worse than no highlight. One source of layout, two consumers.
class TtsHighlightText extends StatelessWidget {
  const TtsHighlightText({
    super.key,
    required this.span,
    required this.textAlign,
    this.rangeStart,
    this.rangeEnd,
  });

  /// The text to render. Already carries whatever styling the reader applies.
  final TextSpan span;
  final TextAlign textAlign;

  /// The highlighted range, in characters of [span]'s plain text. Both null, or
  /// an empty/inverted range, means no highlight.
  final int? rangeStart;
  final int? rangeEnd;

  /// Translucent blue fill, and a near-opaque blue outline.
  static const Color fillColor = Color(0x333B82F6);
  static const Color borderColor = Color(0xE63B82F6);
  static const double borderWidth = 1.2;
  static const double cornerRadius = 6;

  /// Breathing room inside the outline, so the border does not sit on the
  /// glyphs and the box does not look like it is clipping the descenders.
  static const double padHorizontal = 5;
  static const double padVertical = 3;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxes = _boxes(context, constraints.maxWidth);
        return CustomPaint(
          painter: boxes.isEmpty
              ? null
              : _HighlightBoxPainter(
                  boxes,
                  fill: fillColor,
                  border: borderColor,
                ),
          child: Text.rich(span, textAlign: textAlign),
        );
      },
    );
  }

  /// The line boxes the range covers, in the same coordinate space the child
  /// text is painted in.
  List<Rect> _boxes(BuildContext context, double maxWidth) => ttsHighlightBoxes(
        span: span,
        start: rangeStart,
        end: rangeEnd,
        maxWidth: maxWidth,
        textDirection: Directionality.of(context),
        textAlign: textAlign,
        textScaler: MediaQuery.textScalerOf(context),
      );
}

/// The rectangles a read-aloud highlight should be drawn around.
///
/// One entry per line the range touches, in the coordinate space a
/// [TextPainter] laid out with these same arguments produces. Exposed so the
/// geometry can be tested against the text engine's own metrics instead of
/// being asserted through a screenshot.
List<Rect> ttsHighlightBoxes({
  required TextSpan span,
  required int? start,
  required int? end,
  required double maxWidth,
  required TextDirection textDirection,
  TextAlign textAlign = TextAlign.start,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  if (start == null || end == null || end <= start) return const [];
  final text = span.toPlainText();
  if (text.isEmpty) return const [];

  // Clamped rather than rejected: a range that runs past the end of this block
  // or page is normal (a sentence continues overleaf), and the part that *is* on
  // screen still deserves its box.
  final from = start.clamp(0, text.length);
  final to = end.clamp(0, text.length);
  if (to <= from) return const [];

  final painter = TextPainter(
    text: span,
    textDirection: textDirection,
    textAlign: textAlign,
    textScaler: textScaler,
  )..layout(maxWidth: maxWidth.isFinite ? maxWidth : double.infinity);
  final boxes = painter.getBoxesForSelection(
    TextSelection(baseOffset: from, extentOffset: to),
  );
  painter.dispose();
  return [for (final box in boxes) box.toRect()];
}

/// The single rectangle that encloses every box in [boxes].
///
/// One outline around the whole highlighted phrase rather than one per line:
/// a sentence wrapping over three lines should read as one marked phrase, and
/// three stacked outlines read as three unrelated highlights.
///
/// Returns null for an empty list. Pure, so the geometry can be tested without
/// a canvas.
Rect? ttsHighlightRect(List<Rect> boxes) {
  if (boxes.isEmpty) return null;
  var left = boxes.first.left;
  var top = boxes.first.top;
  var right = boxes.first.right;
  var bottom = boxes.first.bottom;
  for (final box in boxes) {
    if (box.left < left) left = box.left;
    if (box.top < top) top = box.top;
    if (box.right > right) right = box.right;
    if (box.bottom > bottom) bottom = box.bottom;
  }
  return Rect.fromLTRB(
    left - TtsHighlightText.padHorizontal,
    top - TtsHighlightText.padVertical,
    right + TtsHighlightText.padHorizontal,
    bottom + TtsHighlightText.padVertical,
  );
}

class _HighlightBoxPainter extends CustomPainter {
  const _HighlightBoxPainter(this.boxes, {required this.fill, required this.border});

  final List<Rect> boxes;
  final Color fill;
  final Color border;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = ttsHighlightRect(boxes);
    if (rect == null) return;
    final rrect = RRect.fromRectAndRadius(
      rect,
      const Radius.circular(TtsHighlightText.cornerRadius),
    );
    canvas.drawRRect(rrect, Paint()..color = fill);
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = TtsHighlightText.borderWidth,
    );
  }

  @override
  bool shouldRepaint(_HighlightBoxPainter old) =>
      old.boxes != boxes || old.fill != fill || old.border != border;
}
