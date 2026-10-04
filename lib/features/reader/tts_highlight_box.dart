import 'package:flutter/material.dart';

/// The read-aloud highlight: a soft lavender fill behind the sentence being
/// spoken, with a dark foreground for comfortable contrast.
///
/// ### Why this is painted rather than styled
///
/// A lightly padded fill is painted per text line, so wrapped sentences read as
/// one continuous highlight without the heavy outlined capsule of the old
/// treatment.
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

  /// Pale periwinkle fill and a readable dark foreground.
  static const Color fillColor = Color(0xFFDDE1FC);
  static const Color textColor = Color(0xFF292A45);
  static const double cornerRadius = 4;

  /// Breathing room around the glyphs without crowding descenders.
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
              : _HighlightBoxPainter(boxes: boxes, fill: fillColor),
          child: Text.rich(
            rangeStart == null || rangeEnd == null || rangeEnd! <= rangeStart!
                ? span
                : _highlightForeground(span, rangeStart!, rangeEnd!),
            textAlign: textAlign,
          ),
        );
      },
    );
  }

  TextSpan _highlightForeground(TextSpan span, int start, int end) {
    var offset = 0;

    List<InlineSpan> visitChildren(Iterable<InlineSpan>? spans) {
      if (spans == null) return const [];
      final result = <InlineSpan>[];
      for (final child in spans) {
        if (child is! TextSpan) {
          result.add(child);
          continue;
        }
        final text = child.text;
        final children = <InlineSpan>[];
        if (text != null && text.isNotEmpty) {
          final from = (start - offset).clamp(0, text.length);
          final to = (end - offset).clamp(0, text.length);
          if (from > 0) {
            children.add(
              TextSpan(text: text.substring(0, from), style: child.style),
            );
          }
          if (to > from) {
            children.add(
              TextSpan(
                text: text.substring(from, to),
                style: (child.style ?? const TextStyle()).copyWith(
                  color: TtsHighlightText.textColor,
                ),
              ),
            );
          }
          if (to < text.length) {
            children.add(
              TextSpan(text: text.substring(to), style: child.style),
            );
          }
          offset += text.length;
        }
        children.addAll(visitChildren(child.children));
        result.add(
          TextSpan(
            style: child.style,
            children: children,
            recognizer: child.recognizer,
            mouseCursor: child.mouseCursor,
            onEnter: child.onEnter,
            onExit: child.onExit,
            semanticsLabel: child.semanticsLabel,
            locale: child.locale,
            spellOut: child.spellOut,
          ),
        );
      }
      return result;
    }

    return TextSpan(
      style: span.style,
      children: visitChildren([span]),
      semanticsLabel: span.semanticsLabel,
      locale: span.locale,
      spellOut: span.spellOut,
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
  const _HighlightBoxPainter({required this.boxes, required this.fill});

  final List<Rect> boxes;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = fill;
    for (final box in boxes) {
      final rect = Rect.fromLTRB(
        box.left - TtsHighlightText.padHorizontal,
        box.top - TtsHighlightText.padVertical,
        box.right + TtsHighlightText.padHorizontal,
        box.bottom + TtsHighlightText.padVertical,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          rect,
          const Radius.circular(TtsHighlightText.cornerRadius),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_HighlightBoxPainter old) =>
      old.boxes != boxes || old.fill != fill;
}
