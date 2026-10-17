import 'package:flutter/material.dart';
import 'package:watch_app/features/reader/tts_alignment.dart';

/// One colour the read-aloud highlight can be.
@immutable
class TtsHighlightChoice {
  const TtsHighlightChoice({
    required this.id,
    required this.label,
    required this.color,
    required this.darkAlpha,
    required this.lightAlpha,
  });

  /// Stored in the reader prefs and carried through to the reader screen.
  final String id;

  /// Shown under the dot in Settings. Not localised, and deliberately so: these
  /// are colour names, and the Font and Theme rows beside this one spell theirs
  /// out in English too.
  final String label;

  final Color color;

  /// Wash strength over a near-black page.
  ///
  /// Higher than [lightAlpha] for the saturated colours and lower for the pale
  /// ones, which is the point of keeping these per colour: a saturated blue
  /// contrasts easily against cream but needs a real wash to register against
  /// black, while a near-white is the other way round.
  final double darkAlpha;

  /// Over a light page - sepia or paper.
  final double lightAlpha;
}

/// Chosen when nothing has been picked, and the fallback for an id that is not
/// in [ttsHighlightPalette] (a downgraded build, a hand-edited box).
const String kDefaultTtsHighlightId = 'blue';

/// The colours the highlight can be, in the order the Settings row shows them.
///
/// ### Why each colour carries its own alpha
///
/// One shared strength cannot serve this list. A wash's visibility depends on
/// how bright its colour is, and these differ a lot: at 20%, coral over
/// near-black composites to about `#3C181D` and reads clearly, while blue at the
/// same 20% lands near `#142339` and is very nearly invisible. A single number
/// would either leave the dim colours useless or make the bright ones shout.
/// So the numbers are tuned per colour and per page, which is dull but is the
/// only way all six read as deliberate marks rather than as three strong ones
/// and three faint smudges.
///
/// Ordered dark-friendly: the first three are the ones that stay legible on a
/// black page without a strong wash, which is where most of this app is read.
List<TtsHighlightChoice> get ttsHighlightPalette => const [
      TtsHighlightChoice(
        id: 'blue',
        label: 'Blue',
        color: Color(0xFF60A5FA),
        darkAlpha: 0.30,
        lightAlpha: 0.24,
      ),
      TtsHighlightChoice(
        id: 'white',
        label: 'White',
        color: Color(0xFFE5E7EB),
        darkAlpha: 0.16,
        lightAlpha: 0.32,
      ),
      TtsHighlightChoice(
        id: 'purple',
        label: 'Purple',
        color: Color(0xFFA78BFA),
        darkAlpha: 0.28,
        lightAlpha: 0.24,
      ),
      TtsHighlightChoice(
        id: 'teal',
        label: 'Teal',
        color: Color(0xFF2DD4BF),
        darkAlpha: 0.24,
        lightAlpha: 0.22,
      ),
      TtsHighlightChoice(
        id: 'amber',
        label: 'Amber',
        color: Color(0xFFFBBF24),
        darkAlpha: 0.22,
        lightAlpha: 0.24,
      ),
      TtsHighlightChoice(
        id: 'coral',
        label: 'Coral',
        color: Color(0xFFFF6B5B),
        darkAlpha: 0.20,
        lightAlpha: 0.24,
      ),
    ];

/// The palette entry for [id], falling back to [kDefaultTtsHighlightId].
///
/// Never returns null and never throws: an unknown id means an older or newer
/// build wrote it, and the right answer is to read in the default colour rather
/// than to refuse to highlight at all.
TtsHighlightChoice ttsHighlightChoiceFor(String? id) {
  final palette = ttsHighlightPalette;
  for (final choice in palette) {
    if (choice.id == id) return choice;
  }
  return palette.firstWhere((c) => c.id == kDefaultTtsHighlightId);
}

/// One colour the highlighted sentence's *text* can be.
@immutable
class TtsHighlightTextChoice {
  const TtsHighlightTextChoice({required this.id, required this.label, this.color});

  /// Stored in the reader prefs and carried through to the reader screen.
  final String id;

  /// Shown under the dot in Settings. Not localised, like the wash palette's.
  final String label;

  /// Null means "leave the sentence in the page's own text colour", which is
  /// what the highlight did until this became a setting.
  final Color? color;
}

/// Chosen when nothing has been picked, and the fallback for an unknown id.
const String kDefaultTtsHighlightTextId = 'default';

/// Colours for the highlighted sentence's text, in Settings order.
///
/// ### Why these are lighter than the wash palette
///
/// A wash is a large flat area behind the words and only has to read as
/// "something is here". The text itself has to beat the wash it sits on, and it
/// has to do that at a readable size against a near-black page. So the same
/// hues appear here a full step brighter - the wash's `#60A5FA` blue would be
/// far too dim as body text, and `#93C5FD` is the same hue lifted until it
/// carries glyphs.
///
/// ### Why there is no black
///
/// This text sits *inside* the wash on a page the reader chooses, and the dark
/// themes are near-black. Black text there is not a style, it is an invisible
/// sentence. On sepia and paper it would be fine, but a setting that works on
/// two of five themes is a worse setting than one that works on all five, so
/// the ink is only ever light. [kDefaultTtsHighlightTextId] - leaving the
/// sentence alone - is the way to get the page's own colour back on a light
/// theme.
List<TtsHighlightTextChoice> get ttsHighlightTextPalette => const [
      TtsHighlightTextChoice(id: 'default', label: 'Default'),
      TtsHighlightTextChoice(
        id: 'white',
        label: 'White',
        color: Color(0xFFFFFFFF),
      ),
      TtsHighlightTextChoice(
        id: 'blue',
        label: 'Blue',
        color: Color(0xFF93C5FD),
      ),
      TtsHighlightTextChoice(
        id: 'purple',
        label: 'Purple',
        color: Color(0xFFC4B5FD),
      ),
      TtsHighlightTextChoice(
        id: 'teal',
        label: 'Teal',
        color: Color(0xFF5EEAD4),
      ),
      TtsHighlightTextChoice(
        id: 'amber',
        label: 'Amber',
        color: Color(0xFFFCD34D),
      ),
      TtsHighlightTextChoice(
        id: 'coral',
        label: 'Coral',
        color: Color(0xFFFFA99E),
      ),
    ];

/// The text palette entry for [id], falling back to [kDefaultTtsHighlightTextId].
TtsHighlightTextChoice ttsHighlightTextChoiceFor(String? id) {
  final palette = ttsHighlightTextPalette;
  for (final choice in palette) {
    if (choice.id == id) return choice;
  }
  return palette.firstWhere((c) => c.id == kDefaultTtsHighlightTextId);
}

/// The read-aloud highlight: a soft accent wash behind the sentence being
/// spoken, one box per line it covers.
///
/// ### Why this is painted rather than styled
///
/// `TextStyle.background` is the only highlight primitive `TextStyle` has, and
/// it cannot round a corner or breathe around the glyphs - a raw background
/// paints hard to the text box, so descenders get clipped and the wash reads as
/// a smudge behind the line rather than a marker around it. `TextStyle` has no
/// border primitive either. So the box has to be painted.
///
/// ### Why one box per line rather than one around the sentence
///
/// It was one box around the whole sentence, on the reasoning that a phrase
/// wrapping over three lines should read as one marked phrase and three stacked
/// outlines read as three unrelated highlights. In practice the opposite
/// happened: one box spanning three lines puts a large empty margin to the left
/// of the first line and to the right of the last, so the mark stops lining up
/// with the words it is describing and the eye has to work out which of the
/// lines it belongs to.
///
/// Per line is what the design asks for, and it is what CSS calls
/// `box-decoration-break: clone`: each line fragment of a wrapped highlight
/// carries its own padding and its own rounded corners, so the shape hugs the
/// text instead of fencing it.
///
/// ### Why it cannot drift out of line with the text
///
/// The rectangles come from a [TextPainter] laid out with the *same* span, width,
/// alignment, direction and text scaler as the [Text.rich] underneath it, and
/// the painter is the parent of that text, so both share one origin. A box
/// positioned from anything else - a measured line height, an assumed character
/// width - lands a few pixels off the words it is meant to be marking, which
/// looks worse than no highlight. One source of layout, two consumers.
class TtsHighlightText extends StatelessWidget {
  const TtsHighlightText({
    super.key,
    required this.span,
    required this.textAlign,
    required this.pageBackground,
    required this.choice,
    this.textChoice,
    this.rangeStart,
    this.rangeEnd,
  });

  /// The text to render. Already carries whatever styling the reader applies.
  final TextSpan span;
  final TextAlign textAlign;

  /// The page behind the text.
  ///
  /// Not decoration: a translucent tint that reads as a soft marker on a near
  /// black page is almost nothing on cream, so the strength has to follow the
  /// page it sits on. Passed in because the app's own theme is dark on every
  /// surface - the reader has its own light page themes (sepia, paper), which
  /// `Theme.of(context).brightness` knows nothing about.
  final Color pageBackground;

  /// Which colour to mark in. Carried in rather than read from prefs here, so
  /// the widget stays a pure function of its inputs and the reader screen - the
  /// only thing that knows the pref - decides.
  final TtsHighlightChoice choice;

  /// Recolours the sentence's text. Null colour on [textChoice] - the default -
  /// leaves the words in whatever style the page gave them, which is what the
  /// highlight did before this was a setting.
  ///
  /// Applied here rather than by the caller because there are two callers and
  /// they are not alike: the scrolling reader builds its spans from the layout
  /// and could style them as it went, but a paginated page was already built and
  /// frozen by the time the sentence is known. Doing it in one place means the
  /// paged mode gets it too, and both modes cannot drift.
  final TtsHighlightTextChoice? textChoice;

  /// The highlighted range, in characters of [span]'s plain text. Both null, or
  /// an empty/inverted range, means no highlight.
  final int? rangeStart;
  final int? rangeEnd;

  static const double cornerRadius = 8;

  /// Breathing room around the glyphs, so the box does not sit on the
  /// descenders and look like it is clipping them.
  static const double padHorizontal = 6;
  static const double padVertical = 3;

  /// Above this the page counts as light. Same threshold the reader uses for
  /// its own background dimming, so the two agree on what "light" means.
  static const double lightPageLuminance = 0.5;

  /// The wash to paint [choice] at over [pageBackground].
  ///
  /// Pure and static so the page-theme rule can be asserted directly, rather
  /// than inferred from a pixel.
  static Color tintFor(Color pageBackground, TtsHighlightChoice choice) {
    final alpha = pageBackground.computeLuminance() > lightPageLuminance
        ? choice.lightAlpha
        : choice.darkAlpha;
    return choice.color.withValues(alpha: alpha);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Restyled once, then used for BOTH the painter and the text. That is
        // the whole reason it is computed here rather than passed in already
        // coloured: the box geometry has to come from the same span the glyphs
        // are painted from, and two constructions of "the same" span is exactly
        // the drift this file exists to prevent.
        final painted = _withTextColour();
        final boxes = _boxes(context, constraints.maxWidth, painted);
        return CustomPaint(
          painter: boxes.isEmpty
              ? null
              : _HighlightBoxPainter(
                  ttsHighlightLineRects(boxes),
                  fill: tintFor(pageBackground, choice),
                ),
          child: Text.rich(painted, textAlign: textAlign),
        );
      },
    );
  }

  /// This widget's span with [textChoice]'s colour merged over the range.
  ///
  /// Returns the span untouched when there is nothing to do, so the common case
  /// costs no tree walk and no allocation.
  TextSpan _withTextColour() {
    final colour = textChoice?.color;
    final start = rangeStart;
    final end = rangeEnd;
    if (colour == null || start == null || end == null || end <= start) {
      return span;
    }
    return applyStyleToRange(span, start, end, TextStyle(color: colour));
  }

  /// The line boxes the range covers, in the same coordinate space the child
  /// text is painted in.
  List<Rect> _boxes(
    BuildContext context,
    double maxWidth,
    TextSpan painted,
  ) =>
      ttsHighlightBoxes(
        span: painted,
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

/// [boxes] padded out to the mark's own inset, one rectangle per line.
///
/// Degenerate entries are dropped: the text engine reports a zero-width box at
/// the end of a range that lands on a line break, and padding one of those
/// draws a lone vertical sliver at the right margin, which reads as a stray
/// mark rather than as part of the sentence.
List<Rect> ttsHighlightLineRects(List<Rect> boxes) => [
      for (final box in boxes)
        if (box.width > 0 && box.height > 0)
          Rect.fromLTRB(
            box.left - TtsHighlightText.padHorizontal,
            box.top - TtsHighlightText.padVertical,
            box.right + TtsHighlightText.padHorizontal,
            box.bottom + TtsHighlightText.padVertical,
          ),
    ];

class _HighlightBoxPainter extends CustomPainter {
  const _HighlightBoxPainter(this.boxes, {required this.fill});

  final List<Rect> boxes;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = fill;
    for (final box in boxes) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          box,
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