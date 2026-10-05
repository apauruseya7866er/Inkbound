import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:watch_app/core/reading/tts/tts_cubit.dart';
import 'package:watch_app/core/reading/tts/tts_prefs.dart';
import 'package:watch_app/core/reading/tts/tts_state.dart';

import 'reader_chrome.dart';

/// The read-aloud panel that floats over the novel text.
///
/// ### One box, opt-in
/// Only appears when the reader's bottom-bar TTS button is tapped, so it costs
/// nothing while simply reading — previously it was on screen for every chapter
/// because the engine being available was enough to show it, which made a
/// read-aloud feature permanent furniture on a page that had not asked for it.
///
/// The sentence, the seek bar and the transport controls are a single box
/// rather than a progress card stacked on a control pill. Two boxes read as two
/// unrelated things and left a seam of page visible between them; one box is
/// also one less rounded rectangle sitting on top of the text.
class TtsPlayerBar extends StatelessWidget {
  const TtsPlayerBar({
    super.key,
    required this.cubit,
    required this.onOpenSettings,
    required this.onOpenPlayer,
    required this.onClose,
  });

  final TtsCubit cubit;
  final VoidCallback onOpenSettings;

  /// Opens the audiobook sheet. Wired to a tap on the progress track's empty
  /// space - the one gesture on this panel that was doing nothing before.
  final VoidCallback onOpenPlayer;

  /// Stops narration and dismisses the panel.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TtsCubit, TtsState>(
      bloc: cubit,
      builder: (context, state) {
        return SafeArea(
          top: false,
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: ReaderPillSurface(
              radius: 16,
              padding: EdgeInsets.zero,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (state.errorMessage != null)
                    _errorNote(state.errorMessage!)
                  else
                    _nowPlaying(state),
                  _divider(),
                  _controls(context, state),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Hairline between the "what's being read" half and the controls half.
  ///
  /// Preferred over a second card because the two are one object: they move
  /// together, and a divider reads as a division *within* something rather than
  /// as a gap between two things.
  Widget _divider() => Container(
    height: 1,
    margin: const EdgeInsets.symmetric(horizontal: 14),
    color: Colors.white.withValues(alpha: 0.10),
  );

  Widget _errorNote(String message) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
    child: Row(
      children: [
        const Icon(Icons.info_outline_rounded, color: Colors.white70, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(color: Colors.white, fontSize: 12.5),
          ),
        ),
      ],
    ),
  );

  /// The sentence being read, plus a seekable bar.
  ///
  /// Seekable because a read-only bar is the worst kind: it advertises a
  /// position the user is told about but cannot act on, and while following
  /// along it is exactly when someone realises they are 80% through a chapter
  /// they only half read.
  Widget _nowPlaying(TtsState state) {
    final total = state.totalSentences;
    final canSeek = total > 0;
    // The real index, never one rebuilt from [TtsState.progress]. Round-tripping
    // the position through a 0..1 fraction and back loses a sentence at the end
    // of the chapter: at the last one it reported "162 of 163" while the voice
    // and the highlight were both on 163, which looks exactly like the final
    // line being skipped.
    final current = canSeek ? state.currentIndex.clamp(0, total - 1) : 0;
    final speaking = state.currentSentence?.text ?? '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The sentence itself, so the user can see what is being read and not
          // have to trust the audio. Clipped to one line: the panel sits over the
          // text, and a paragraph-length quote would bury the page.
          Text(
            speaking.isEmpty ? 'Not reading yet' : speaking,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: speaking.isEmpty ? Colors.white54 : Colors.white,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 2),
          _SeekBar(
            total: total,
            position: current,
            onSeek: canSeek ? cubit.seek : null,
            onOpenPlayer: onOpenPlayer,
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  canSeek
                      ? 'Sentence ${current + 1} of $total'
                      : 'No sentences yet',
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ),
              // Beside the counter rather than as a sixth icon in the transport
              // row. That row is five controls because it reads as a transport,
              // and six would put two different-sized targets either side of the
              // play button. This is metadata, and it belongs with the other
              // metadata.
              _SpeedChip(
                rate: state.rate,
                onTap: () => cubit.setRate(TtsSpeed.next(state.rate)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _controls(BuildContext context, TtsState state) {
    final canSeek = state.isActive && state.totalSentences > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
      child: Row(
        // The parent Column stretches its children, so this Row gets tight
        // width constraints and `mainAxisSize` is ignored. Without an explicit
        // centre alignment the five icons fall to `start` and hug the left edge,
        // which reads as a half-finished toolbar rather than a transport row.
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _icon(
            state.isSpeaking
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
            state.isSpeaking ? 'Pause reading aloud' : 'Read aloud',
            () => cubit.toggle(),
            enabled: state.available && state.totalSentences > 0,
            // Distinct from a disabled control: this is the primary action and
            // is the one users reach for by muscle memory.
            emphasised: true,
          ),
          // One sentence, not ten. These sit either side of the sentence quoted
          // directly above, so "back 10" jumped past the very text on screen and
          // left the reader hunting for where they had been.
          _icon(
            Icons.skip_previous_rounded,
            'Previous sentence',
            () => cubit.skip(-1),
            enabled: canSeek,
          ),
          _icon(
            Icons.skip_next_rounded,
            'Next sentence',
            () => cubit.skip(1),
            enabled: canSeek,
          ),
          _icon(Icons.tune_rounded, 'Reading settings', onOpenSettings),
          _icon(Icons.close_rounded, 'Stop reading aloud', onClose),
        ],
      ),
    );
  }

  Widget _icon(
    IconData icon,
    String tooltip,
    VoidCallback onTap, {
    bool enabled = true,
    bool emphasised = false,
  }) {
    final button = IconButton(
      onPressed: enabled ? onTap : null,
      iconSize: 21,
      color: emphasised ? Colors.white : Colors.white70,
      disabledColor: Colors.white24,
      icon: Icon(icon),
    );
    // Labelled for TalkBack, same reasoning as ReaderPillIconButton: an
    // icon-only control is otherwise an unnamed tap target.
    return Tooltip(
      message: tooltip,
      child: Semantics(button: true, label: tooltip, child: button),
    );
  }
}

/// The tappable speed control: shows the current rate, steps to the next preset
/// when tapped.
///
/// A label rather than an icon, because there is no speed glyph that means
/// anything to anyone, and a chip that reads "1.5x" needs no legend — it is the
/// one control in the panel whose state has to be visible rather than inferred.
///
/// Stays tappable when the engine is unavailable. Setting a speed before
/// starting is a reasonable thing to want, and the value persists either way.
class _SpeedChip extends StatelessWidget {
  const _SpeedChip({required this.rate, required this.onTap});

  final double rate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = TtsSpeed.label(rate);
    return Tooltip(
      message: 'Speech speed $label. Tap for the next speed.',
      child: Semantics(
        button: true,
        label: 'Speech speed $label',
        child: Material(
          color: Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(9),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A draggable sentence-position bar, and the way into the audiobook player.
///
/// A tap on the track's empty space opens the player; a drag scrubs. Those are
/// different gestures on the same widget, which is why this is a painted track
/// rather than a [Slider]: a Slider claims the tap itself and jumps its thumb
/// there, so the tap could never reach us.
///
/// ### What that costs, and what it buys back
///
/// [Slider] gave keyboard, TalkBack and thumb-drag behaviour for free, and a
/// hand-rolled track has to state all three itself. So the semantics are
/// explicit above the gesture detector: a labelled slider with a value, an
/// increase and a decrease action, and the tap that opens the player.
///
/// ### Why it commits on release, not on every drag update
///
/// Committing per pixel of travel fires once per frame, and every one of those
/// calls restarts the engine. Dragging across a chapter then reads as a
/// stutter that ends up back on the sentence you started from, because the
/// thumb is driven by the position the drag is itself changing. So the drag
/// moves a local value and only the release is committed.
///
/// Stateful for that local value. Stateless would mean re-deriving it from
/// [position] on every rebuild, which is the position being overwritten by the
/// very seek in progress.
class _SeekBar extends StatefulWidget {
  const _SeekBar({
    required this.total,
    required this.position,
    required this.onSeek,
    required this.onOpenPlayer,
  });

  final int total;
  final int position;
  final ValueChanged<int>? onSeek;

  /// Fired on a tap rather than a drag.
  final VoidCallback onOpenPlayer;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  /// The thumb position while the user is dragging it, which is ahead of the
  /// position speech has actually reached.
  int? _dragging;

  /// True once the pointer has moved far enough to count as a scrub, so the
  /// release of a drag does not ALSO fire the tap that opens the player.
  bool _dragged = false;

  @override
  void didUpdateWidget(_SeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A seek from elsewhere (a sentence button, auto-advance) must not be
    // masked by a stale drag value left over from a previous scrub.
    if (_dragging == null && oldWidget.position != widget.position) {
      setState(() {});
    }
  }

  void _commit(double value) {
    setState(() => _dragging = null);
    widget.onSeek?.call(value.round());
  }

  /// The sentence under [dx], given the track's width.
  double? _valueAt(double dx, double width) {
    final total = widget.total;
    if (total <= 1 || width <= 0) return null;
    // 4px of inset at each end matches the painted track.
    final usable = width - 8;
    if (usable <= 0) return null;
    final fraction = ((dx - 4) / usable).clamp(0.0, 1.0);
    return fraction * (total - 1);
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.total;
    final seekable = widget.onSeek != null;

    final max = total > 1 ? (total - 1).toDouble() : 1.0;
    final value =
        (_dragging ?? widget.position).toDouble().clamp(0, max).toDouble();
    final fraction = total > 1 ? (value / max).clamp(0.0, 1.0) : 0.0;

    final shown = value.round();
    final atEnd = shown >= total - 1;
    return Semantics(
      slider: total > 1,
      label: 'Audiobook progress',
      value: seekable
          ? 'Sentence ${shown + 1} of $total'
          : 'No sentences',
      onTap: widget.onOpenPlayer,
      onIncrease: seekable && total > 1 && !atEnd
          ? () => widget.onSeek!(shown + 1)
          : null,
      // Flutter requires a non-null increasedValue/decreasedValue wherever the
      // matching action exists, or the semantics tree asserts.
      increasedValue: seekable && total > 1
          ? 'Sentence ${(shown + 1).clamp(0, total - 1) + 1} of $total'
          : null,
      onDecrease: seekable && total > 1 && shown > 0
          ? () => widget.onSeek!(shown - 1)
          : null,
      decreasedValue: seekable && total > 1
          ? 'Sentence ${(shown - 1).clamp(0, total - 1) + 1} of $total'
          : null,
      child: Tooltip(
        message: 'Tap to open the audiobook player; drag to seek',
        child: SizedBox(
          height: 24,
          child: LayoutBuilder(
            builder: (context, c) => GestureDetector(
              key: const ValueKey('compact-tts-progress'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                // A drag that ends here has already seeked; opening the player
                // on top of that would be two answers to one gesture.
                if (_dragged) {
                  setState(() => _dragged = false);
                  return;
                }
                widget.onOpenPlayer();
              },
              onHorizontalDragStart: seekable && total > 1
                  ? (d) {
                      setState(() => _dragged = true);
                      final v = _valueAt(d.localPosition.dx, c.maxWidth);
                      if (v != null) setState(() => _dragging = v.round());
                    }
                  : null,
              onHorizontalDragUpdate: seekable && total > 1
                  ? (d) {
                      final v = _valueAt(d.localPosition.dx, c.maxWidth);
                      if (v != null) setState(() => _dragging = v.round());
                    }
                  : null,
              onHorizontalDragEnd: seekable && total > 1
                  ? (_) {
                      final d = _dragging;
                      if (d != null) _commit(d.toDouble());
                    }
                  : null,
              child: CustomPaint(
                size: Size(c.maxWidth, 24),
                painter: _SeekTrackPainter(progress: fraction),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The compact progress track: a 3px line with a 5px round thumb.
class _SeekTrackPainter extends CustomPainter {
  const _SeekTrackPainter({required this.progress});

  final double progress;

  static const double _inset = 4;
  static const double _trackHeight = 3;
  static const double _thumbRadius = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final centreY = size.height / 2;
    final width = size.width - _inset * 2;
    if (width <= 0) return;
    final activeWidth = width * progress.clamp(0.0, 1.0);

    canvas.drawLine(
      Offset(_inset, centreY),
      Offset(size.width - _inset, centreY),
      Paint()
        ..color = Colors.white24
        ..strokeWidth = _trackHeight
        ..strokeCap = StrokeCap.round,
    );
    if (activeWidth > 0) {
      canvas.drawLine(
        Offset(_inset, centreY),
        Offset(_inset + activeWidth, centreY),
        Paint()
          ..color = Colors.white
          ..strokeWidth = _trackHeight
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawCircle(
      Offset(_inset + activeWidth, centreY),
      _thumbRadius,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_SeekTrackPainter old) => old.progress != progress;
}
