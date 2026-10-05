import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:watch_app/core/reading/tts/tts_cubit.dart';
import 'package:watch_app/core/reading/tts/tts_prefs.dart';
import 'package:watch_app/core/reading/tts/tts_state.dart';
import 'package:watch_app/core/theme/app_colors.dart';

/// Opens the read-aloud audiobook sheet over the reader.
///
/// A sheet and not a pushed route: the page stays behind it, and dismissing it
/// hands the reader straight back without interrupting narration - which runs in
/// a foreground service and does not care what is on screen.
Future<void> showTtsAudiobookSheet(
  BuildContext context, {
  required TtsCubit cubit,
  required String bookTitle,
  required String Function() chapterTitle,
  required bool canPreviousChapter,
  required bool canNextChapter,
  required VoidCallback onPreviousChapter,
  required VoidCallback onNextChapter,
  String? cover,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (_) => TtsAudiobookSheet(
      cubit: cubit,
      bookTitle: bookTitle,
      chapterTitle: chapterTitle,
      canPreviousChapter: canPreviousChapter,
      canNextChapter: canNextChapter,
      onPreviousChapter: onPreviousChapter,
      onNextChapter: onNextChapter,
      cover: cover,
    ),
  );
}

enum _SheetView { player, lyrics }

/// The audiobook player and its lyric-style transcript, sharing one sheet and
/// one header, so moving between them is a toggle rather than a navigation.
class TtsAudiobookSheet extends StatefulWidget {
  const TtsAudiobookSheet({
    super.key,
    required this.cubit,
    required this.bookTitle,
    required this.chapterTitle,
    required this.canPreviousChapter,
    required this.canNextChapter,
    required this.onPreviousChapter,
    required this.onNextChapter,
    this.cover,
  });

  final TtsCubit cubit;
  final String bookTitle;

  /// Read on every build, not captured once: auto-advance changes the chapter
  /// while this is open and the title has to follow it.
  final String Function() chapterTitle;
  final String? cover;

  final bool canPreviousChapter;
  final bool canNextChapter;
  final VoidCallback onPreviousChapter;
  final VoidCallback onNextChapter;

  @override
  State<TtsAudiobookSheet> createState() => _TtsAudiobookSheetState();
}

class _TtsAudiobookSheetState extends State<TtsAudiobookSheet> {
  _SheetView _view = _SheetView.player;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.92,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        child: Material(
          // Material, not a ColoredBox: the quick actions are InkWells, which
          // assert on a missing Material ancestor when they build.
          color: AppColors.bg,
          child: BlocBuilder<TtsCubit, TtsState>(
            bloc: widget.cubit,
            builder: (context, state) {
              final total = state.totalSentences;
              final current = total == 0
                  ? 0
                  : state.currentIndex.clamp(0, total - 1);
              return Stack(
                fit: StackFit.expand,
                children: [
                  _BlurredBackdrop(cover: widget.cover),
                  SafeArea(
                    top: false,
                    child: Column(
                      children: [
                        _SheetHeader(
                          onClose: () => Navigator.of(context).maybePop(),
                          showingLyrics: _view == _SheetView.lyrics,
                          onToggleView: () => setState(() {
                            _view = _view == _SheetView.player
                                ? _SheetView.lyrics
                                : _SheetView.player;
                          }),
                        ),
                        Expanded(
                          child: _view == _SheetView.player
                              ? _PlayerBody(
                                  cover: widget.cover,
                                  chapterTitle: widget.chapterTitle(),
                                  bookTitle: widget.bookTitle,
                                )
                              : _LyricsBody(
                                  cubit: widget.cubit,
                                  state: state,
                                  current: current,
                                ),
                        ),
                        _WaveformProgress(
                          cubit: widget.cubit,
                          state: state,
                          current: current,
                        ),
                        _CounterRow(state: state, current: current),
                        _TransportRow(
                          cubit: widget.cubit,
                          state: state,
                          current: current,
                          canPreviousChapter: widget.canPreviousChapter,
                          canNextChapter: widget.canNextChapter,
                          onPreviousChapter: widget.onPreviousChapter,
                          onNextChapter: widget.onNextChapter,
                          onShuffle: () {
                            if (total < 2) return;
                            final next = math.Random().nextInt(total);
                            if (next != current) widget.cubit.seek(next);
                          },
                        ),
                        _QuickActions(cubit: widget.cubit, state: state),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.onClose,
    required this.showingLyrics,
    required this.onToggleView,
  });

  final VoidCallback onClose;
  final bool showingLyrics;
  final VoidCallback onToggleView;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('audiobook-sheet-close'),
            tooltip: 'Close player',
            onPressed: onClose,
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 28),
            color: AppColors.textPrimary,
          ),
          const Expanded(
            child: Text(
              'READING NOW',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 2.4,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('audiobook-sheet-toggle'),
            tooltip: showingLyrics ? 'Back to player' : 'Open lyrics',
            onPressed: onToggleView,
            icon: Icon(
              showingLyrics ? Icons.list_rounded : Icons.lyrics_rounded,
              size: 24,
            ),
            color: AppColors.accent,
          ),
        ],
      ),
    );
  }
}

/// The cover, blurred and dimmed, behind everything.
///
/// In a [RepaintBoundary] so scrolling the transcript never re-runs the blur.
class _BlurredBackdrop extends StatelessWidget {
  const _BlurredBackdrop({this.cover});

  final String? cover;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (cover != null && cover!.isNotEmpty)
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 46, sigmaY: 46),
              child: CachedNetworkImage(
                imageUrl: cover!,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          // Two stops rather than one flat wash: the top keeps the header
          // legible over a pale cover, the bottom sinks the transport row.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.bg.withValues(alpha: 0.80),
                  AppColors.bg.withValues(alpha: 0.93),
                  AppColors.bg,
                ],
                stops: const [0, 0.45, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerBody extends StatelessWidget {
  const _PlayerBody({
    required this.cover,
    required this.chapterTitle,
    required this.bookTitle,
  });

  final String? cover;
  final String chapterTitle;
  final String bookTitle;

  /// Room the title block needs under the cover, so the cover never grows into
  /// it and pushes the layout off the bottom of the sheet.
  static const double _titlesReserve = 96;

  @override
  Widget build(BuildContext context) {
    // Sized from the space this body is actually given, not from the window.
    //
    // The window is the wrong reference: the sheet hands this body whatever is
    // left after the header, the waveform, the transport and the quick actions,
    // so measuring against the screen capped the cover well below what was
    // available and the slack surfaced as a gap above the waveform.
    return LayoutBuilder(
      builder: (context, c) {
        final side = math
            .min(c.maxWidth, (c.maxHeight - _titlesReserve) * 0.92)
            .clamp(120.0, 480.0)
            .toDouble();
        final vertical = math.max(0.0, c.maxHeight - 16);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: ConstrainedBox(
            // Centres the artwork in whatever height there is, and still scrolls
            // on a short screen rather than overflowing.
            constraints: BoxConstraints(minHeight: vertical),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
Container(
            key: const ValueKey('audiobook-cover'),
            width: side,
            height: side,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: AppColors.surface2,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: (cover == null || cover!.isEmpty)
                      ? const Icon(
                          Icons.menu_book_rounded,
                          size: 84,
                          color: AppColors.textTertiary,
                        )
                      : CachedNetworkImage(
                          imageUrl: cover!,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => const Icon(
                            Icons.menu_book_rounded,
                            size: 84,
                            color: AppColors.textTertiary,
                          ),
                        ),
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chapterTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        bookTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LyricsBody extends StatefulWidget {
  const _LyricsBody({
    required this.cubit,
    required this.state,
    required this.current,
  });

  final TtsCubit cubit;
  final TtsState state;
  final int current;

  @override
  State<_LyricsBody> createState() => _LyricsBodyState();
}

class _LyricsBodyState extends State<_LyricsBody> {
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};
  int _lastRevealed = -1;

  // Shared by the real rows and by [_estimateExtent], so the estimate cannot
  // drift away from the layout it is estimating.
  static const double _rowPadding = 8;
  static const double _gutter = 26;
  static const double _fontIdle = 22;
  static const double _fontActive = 26;
  static const double _lineHeight = 1.3;

  @override
  void initState() {
    super.initState();
    // The transcript is built fresh every time the view is toggled on, and
    // didUpdateWidget does not fire for a widget's own first build. Without this
    // the view opened at the top of the chapter and the reader had to scroll to
    // find the sentence being read.
    _revealCurrent();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _LyricsBody old) {
    super.didUpdateWidget(old);
    if (widget.current != _lastRevealed) _revealCurrent();
  }


  void _revealCurrent() {
    final index = widget.current;
    if (index == _lastRevealed) return;
    _lastRevealed = index;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(index));
  }

  /// Puts sentence [index] in the middle of the view.
  ///
  /// A lazily built list has no context for a line it has never laid out, so a
  /// spoken sentence near the end of a long chapter cannot simply be measured -
  /// there is nothing to measure. So this converges instead: jump to an
  /// estimate, which builds the line, then correct using the average height of
  /// the lines that are now genuinely on screen, and repeat.
  ///
  /// The correction matters. Estimating from character counts alone assumes a
  /// font's average glyph width, and a wider font - a bold face, a large
  /// system text scale, or the fixed-width test font - makes every guess short
  /// and the target lands further and further below the viewport.
  void _reveal(int index) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _step(index, 0));
  }

  void _step(int index, int attempt) {
    if (!mounted || attempt > 5) return;

    void settle() {
      if (!mounted) return;
      final ctx = _keys[index]?.currentContext;
      if (ctx == null) {
        // Still not built. Clear the guard so the next sentence tries again
        // rather than the view staying stuck where it is.
        _lastRevealed = -1;
        return;
      }
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }

    final ctx = _keys[index]?.currentContext;
    if (ctx != null) {
      settle();
      return;
    }
    if (!_scroll.hasClients) {
      _lastRevealed = -1;
      return;
    }

    final position = _scroll.position;
    final average = _measuredAverageExtent() ?? _estimateExtent(index);
    final top = widget.state.sentences.isEmpty
        ? 0.0
        : MediaQuery.sizeOf(context).height * 0.20;
    final target = (top + average * index).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < 1) {
      _lastRevealed = -1;
      return;
    }
    _scroll.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _step(index, attempt + 1),
    );
  }

  /// Average height of the transcript lines currently laid out, or null when
  /// nothing has been built yet.
  double? _measuredAverageExtent() {
    var total = 0.0;
    var count = 0;
    for (final key in _keys.values) {
      final ctx = key.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject();
      if (box is RenderBox && box.hasSize && box.size.height > 0) {
        total += box.size.height;
        count++;
      }
    }
    return count == 0 ? null : total / count;
  }

  /// First-guess height of a transcript line, from its text.
  ///
  /// Only a starting point; [_measuredAverageExtent] replaces it as soon as any
  /// real line has been laid out.
  double _estimateExtent(int index) {
    final sentences = widget.state.sentences;
    final text = index < sentences.length ? sentences[index].text.trim() : '';
    final width = MediaQuery.sizeOf(context).width - _gutter * 2;
    final perLine = math.max(8.0, width / (_fontIdle * 0.52));
    final lines = text.isEmpty ? 1 : (text.length / perLine).ceil();
    return lines * _fontIdle * _lineHeight + _rowPadding * 2;
  }

  @override
  Widget build(BuildContext context) {
    final sentences = widget.state.sentences;
    _keys.removeWhere((i, _) => i >= sentences.length);
    if (sentences.isEmpty) {
      return const Center(
        child: Text(
          'No transcript available yet',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }
    final viewport = MediaQuery.sizeOf(context).height;
    return ListView.builder(
      controller: _scroll,
      padding: EdgeInsets.symmetric(vertical: viewport * 0.20, horizontal: _gutter),
      itemCount: sentences.length,
      itemBuilder: (context, i) {
        final distance = (i - widget.current).abs();
        final active = distance == 0;
        final opacity = active
            ? 1.0
            : (0.62 - distance * 0.1).clamp(0.16, 0.56);
        return Semantics(
          button: true,
          label: 'Sentence ${i + 1}',
          child: GestureDetector(
            key: _keys.putIfAbsent(i, GlobalKey.new),
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.cubit.seek(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: _rowPadding),
              child: Text(
                sentences[i].text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textPrimary.withValues(alpha: opacity),
                  fontSize: active ? _fontActive : _fontIdle,
                  height: _lineHeight,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The audiobook-style waveform.
///
/// Bar heights come from each sentence's own character count, so this is a map
/// of the chapter rather than decoration: it shows how much is left, and a tap
/// or a drag seeks to the sentence under the finger. Deterministic rather than
/// random, so it does not reshuffle itself on every rebuild.
/// The audiobook-style waveform, and the way to seek by position.
///
/// Bar heights come from each sentence's own character count, so this is a map
/// of the chapter rather than decoration: it shows how much is left, and a tap
/// or a drag seeks to the sentence under the finger.
///
/// ### Why the drag value is local to this widget
///
/// It used to be lifted into the sheet so the thumb could follow a drag, and a
/// tap was written as "remember on tap-down, commit on tap-up". That is broken:
/// a tap commits against the value captured when this widget was BUILT, and no
/// rebuild happens between a tap-down and its tap-up, so the commit read null,
/// the tap did nothing, and the value left behind in the parent was then
/// committed by whatever the reader touched next - which is how a tap near the
/// left could throw the narration to the end of the chapter.
///
/// Holding the drag here and committing a tap straight from the tap's own
/// position removes the value that could go stale. There is nothing to leak.
class _WaveformProgress extends StatefulWidget {
  const _WaveformProgress({
    required this.cubit,
    required this.state,
    required this.current,
  });

  final TtsCubit cubit;
  final TtsState state;
  final int current;

  @override
  State<_WaveformProgress> createState() => _WaveformProgressState();
}

class _WaveformProgressState extends State<_WaveformProgress> {
  /// Sentence under the finger mid-drag, or null when the cubit is the
  /// authority. Local so the thumb cannot be driven by a value from a previous
  /// gesture.
  int? _drag;

  static const double _inset = 4;
  static const int _barGap = 2;
  static const int _maxBars = 86;

  /// The sentence at [dx], or null when there is nothing to seek between.
  int? _indexAt(double dx, double width, int total) {
    if (total < 2) return null;
    final usable = width - _inset * 2;
    if (usable <= 0) return null;
    final fraction = ((dx - _inset) / usable).clamp(0.0, 1.0);
    return (fraction * (total - 1)).round();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final total = state.totalSentences;
    final shown = _drag ?? widget.current;
    final progress = total < 2
        ? 0.0
        : (shown / (total - 1)).clamp(0.0, 1.0).toDouble();

    final weights = <double>[];
    for (var i = 0; i < total; i++) {
      final s = i < state.sentences.length ? state.sentences[i] : null;
      final chars = s == null ? 40 : s.text.trim().length;
      weights.add(0.22 + (chars / 120).clamp(0.0, 1.0) * 0.78);
    }

    final canStep = total > 1;
    return Semantics(
      slider: canStep,
      label: 'Audiobook progress',
      value: canStep ? 'Sentence ${shown + 1} of $total' : 'No sentences',
      onIncrease: canStep ? () => widget.cubit.seek(shown + 1) : null,
      // Required wherever the matching action exists, or the semantics tree
      // asserts on a node that can increase but reports no new value.
      increasedValue: canStep
          ? 'Sentence ${(shown + 1).clamp(0, total - 1) + 1} of $total'
          : null,
      onDecrease: canStep ? () => widget.cubit.seek(shown - 1) : null,
      decreasedValue: canStep
          ? 'Sentence ${(shown - 1).clamp(0, total - 1) + 1} of $total'
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22),
        child: LayoutBuilder(
          builder: (context, c) => GestureDetector(
            key: const ValueKey('audiobook-waveform'),
            behavior: HitTestBehavior.opaque,
            // Committed from the tap's own position, on the way up. No remembered
            // value, so no stale one.
            onTapUp: (d) {
              final index = _indexAt(d.localPosition.dx, c.maxWidth, total);
              if (index != null) widget.cubit.seek(index);
            },
            onHorizontalDragStart: total > 1
                ? (d) {
                    final index = _indexAt(
                      d.localPosition.dx,
                      c.maxWidth,
                      total,
                    );
                    if (index != null) setState(() => _drag = index);
                  }
                : null,
            onHorizontalDragUpdate: total > 1
                ? (d) {
                    final index = _indexAt(
                      d.localPosition.dx,
                      c.maxWidth,
                      total,
                    );
                    if (index != null) setState(() => _drag = index);
                  }
                : null,
            onHorizontalDragEnd: total > 1
                ? (_) {
                    final index = _drag;
                    setState(() => _drag = null);
                    if (index != null) widget.cubit.seek(index);
                  }
                : null,
            onHorizontalDragCancel: () => setState(() => _drag = null),
            child: CustomPaint(
              size: Size(c.maxWidth, 44),
              painter: _WaveformPainter(
                weights: weights,
                progress: progress,
                barGap: _barGap,
                maxBars: _maxBars,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({
    required this.weights,
    required this.progress,
    required this.barGap,
    required this.maxBars,
  });

  final List<double> weights;
  final double progress;
  final int barGap;
  final int maxBars;

  @override
  void paint(Canvas canvas, Size size) {
    if (weights.isEmpty || size.width <= 0) return;
    final count = math.min(weights.length, maxBars);
    final gap = barGap.toDouble();
    final barWidth = math.max(1.5, (size.width - gap * (count - 1)) / count);
    final played = Paint()
      ..color = AppColors.textPrimary
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;
    final unplayed = Paint()
      ..color = Colors.white24
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;
    final centreY = size.height / 2;

    for (var i = 0; i < count; i++) {
      final h = (size.height * weights[i]).clamp(4.0, size.height);
      final x = 4 + i * (barWidth + gap);
      // Bars are a map of the chapter, so the filled portion follows the
      // sentence index rather than an equal share of the bars.
      final fraction = count < 2 ? 0.0 : i / (count - 1);
      canvas.drawLine(
        Offset(x, centreY - h / 2),
        Offset(x, centreY + h / 2),
        fraction <= progress ? played : unplayed,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress || old.weights != weights;
}

class _CounterRow extends StatelessWidget {
  const _CounterRow({required this.state, required this.current});

  final TtsState state;
  final int current;

  /// Rough time left, from the characters still to read at the current rate.
  ///
  /// An estimate, and deliberately coarse: there is no duration per sentence,
  /// and a real voice's pace with its punctuation pauses cannot be derived from
  /// characters. ~900 characters a minute at 1.0x is a reasonable middle.
  String _left() {
    final total = state.totalSentences;
    if (total == 0) return '';
    var chars = 0;
    for (var i = current; i < total && i < state.sentences.length; i++) {
      chars += state.sentences[i].text.trim().length;
    }
    if (chars == 0) return '';
    final perMinute = 900.0 * (state.rate <= 0 ? 1.0 : state.rate);
    return '~${(chars / perMinute).ceil()} min left';
  }

  @override
  Widget build(BuildContext context) {
    final total = state.totalSentences;
    final left = _left();
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 2, 26, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            total == 0 ? '0 / 0' : '${current + 1} / $total',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
          if (left.isNotEmpty)
            Text(
              left,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
        ],
      ),
    );
  }
}

class _TransportRow extends StatelessWidget {
  const _TransportRow({
    required this.cubit,
    required this.state,
    required this.current,
    required this.canPreviousChapter,
    required this.canNextChapter,
    required this.onPreviousChapter,
    required this.onNextChapter,
    required this.onShuffle,
  });

  final TtsCubit cubit;
  final TtsState state;
  final int current;
  final bool canPreviousChapter;
  final bool canNextChapter;
  final VoidCallback onPreviousChapter;
  final VoidCallback onNextChapter;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    final total = state.totalSentences;
    final canStep = total > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            tooltip: 'Jump to a random sentence',
            onPressed: canStep ? onShuffle : null,
            icon: const Icon(Icons.shuffle_rounded),
            color: AppColors.textSecondary,
          ),
          // Chapter, not sentence. These are the transport's skip-track buttons
          // and they sat either side of the play control doing exactly what
          // -1 Sent / +1 Sent do, two controls for one job. Stepping a sentence
          // is the quick row's; skipping a chapter is this row's.
          IconButton(
            key: const ValueKey('audiobook-prev-chapter'),
            tooltip: 'Previous chapter',
            onPressed: canPreviousChapter ? onPreviousChapter : null,
            icon: const Icon(Icons.skip_previous_rounded),
            iconSize: 32,
            color: AppColors.textPrimary,
          ),
          IconButton(
            key: const ValueKey('audiobook-play'),
            tooltip: state.isSpeaking ? 'Pause' : 'Play',
            onPressed: state.available && canStep ? cubit.toggle : null,
            icon: Icon(
              state.isSpeaking ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
            iconSize: 44,
            color: AppColors.bg,
            style: IconButton.styleFrom(
              backgroundColor: AppColors.textPrimary,
              fixedSize: const Size(72, 72),
            ),
          ),
          IconButton(
            key: const ValueKey('audiobook-next-chapter'),
            tooltip: 'Next chapter',
            onPressed: canNextChapter ? onNextChapter : null,
            icon: const Icon(Icons.skip_next_rounded),
            iconSize: 32,
            color: AppColors.textPrimary,
          ),
          // Balances the shuffle on the left so the transport stays centred.
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.cubit, required this.state});

  final TtsCubit cubit;
  final TtsState state;

  static const List<int> _sleepCycle = <int>[0, 5, 15, 30, 60];

  @override
  Widget build(BuildContext context) {
    final canStep = state.totalSentences > 0;
    final sleepLabel = state.sleepTimerMinutes == 0
        ? 'Sleep Timer'
        : '${state.sleepTimerMinutes}m';

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _QuickAction(
            key: const ValueKey('audiobook-sleep'),
            icon: Icons.timer_outlined,
            label: sleepLabel,
            onTap: () {
              final at = _sleepCycle.indexOf(state.sleepTimerMinutes);
              cubit.setSleepTimer(_sleepCycle[(at + 1) % _sleepCycle.length]);
            },
          ),
          _QuickAction(
            key: const ValueKey('audiobook-minus-sentence'),
            icon: Icons.keyboard_double_arrow_left_rounded,
            label: '-1 Sent',
            onTap: canStep ? () => cubit.skip(-1) : null,
          ),
          _QuickAction(
            key: const ValueKey('audiobook-plus-sentence'),
            icon: Icons.keyboard_double_arrow_right_rounded,
            label: '+1 Sent',
            onTap: canStep ? () => cubit.skip(1) : null,
          ),
          _QuickAction(
            key: const ValueKey('audiobook-speed'),
            icon: Icons.speed_rounded,
            label: '${state.rate.toStringAsFixed(1)}x',
            onTap: () => cubit.setRate(TtsSpeed.next(state.rate)),
          ),
        ],
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tint = onTap == null ? AppColors.textTertiary : AppColors.textPrimary;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: tint),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(color: tint, fontSize: 11.5)),
            ],
          ),
        ),
      ),
    );
  }
}
