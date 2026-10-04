import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:watch_app/core/reading/tts/tts_cubit.dart';
import 'package:watch_app/core/reading/tts/tts_prefs.dart';
import 'package:watch_app/core/reading/tts/tts_state.dart';
import 'package:watch_app/core/theme/app_colors.dart';

/// Full-screen audiobook controls and a synchronized, lyrics-style transcript.
class TtsFullPlayer extends StatefulWidget {
  const TtsFullPlayer({
    super.key,
    required this.cubit,
    required this.bookTitle,
    required this.chapterTitle,
    required this.cover,
    required this.onOpenSettings,
  });

  final TtsCubit cubit;
  final String bookTitle;
  final String Function() chapterTitle;
  final String? cover;
  final VoidCallback onOpenSettings;

  @override
  State<TtsFullPlayer> createState() => _TtsFullPlayerState();
}

class _TtsFullPlayerState extends State<TtsFullPlayer> {
  void _openLyrics() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TtsLyricsPage(
          cubit: widget.cubit,
          bookTitle: widget.bookTitle,
          chapterTitle: widget.chapterTitle,
          onOpenSettings: widget.onOpenSettings,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TtsCubit, TtsState>(
      bloc: widget.cubit,
      builder: (context, state) {
        final size = MediaQuery.sizeOf(context);
        final coverSize = math.min(
          (size.width - 64).clamp(150.0, 420.0),
          (size.height * .42).clamp(150.0, 360.0),
        );
        return Scaffold(
          backgroundColor: AppColors.bg,
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _topButton(
                        icon: Icons.keyboard_arrow_down_rounded,
                        label: 'Close player',
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const Expanded(
                        child: Text(
                          'NOW PLAYING',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2.4,
                          ),
                        ),
                      ),
                      _topButton(
                        icon: Icons.lyrics_rounded,
                        label: 'Open lyrics',
                        onPressed: _openLyrics,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Container(
                    width: coverSize,
                    height: coverSize,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: widget.cover == null || widget.cover!.isEmpty
                        ? const Icon(
                            Icons.menu_book_rounded,
                            size: 88,
                            color: AppColors.textTertiary,
                          )
                        : CachedNetworkImage(
                            imageUrl: widget.cover!,
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) => const Icon(
                              Icons.menu_book_rounded,
                              size: 88,
                              color: AppColors.textTertiary,
                            ),
                          ),
                  ),
                  const SizedBox(height: 26),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.chapterTitle(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.bookTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Open lyrics',
                        onPressed: _openLyrics,
                        icon: const Icon(Icons.lyrics_rounded),
                        color: AppColors.textSecondary,
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  _FullPlayerProgress(cubit: widget.cubit, state: state),
                  const SizedBox(height: 20),
                  _MainTransport(cubit: widget.cubit, state: state),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _smallAction(
                        icon: Icons.tune_rounded,
                        label: 'Settings',
                        onTap: widget.onOpenSettings,
                      ),
                      _smallAction(
                        icon: Icons.speed_rounded,
                        label: '${state.rate.toStringAsFixed(1)}× speed',
                        onTap: () =>
                            widget.cubit.setRate(TtsSpeed.next(state.rate)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _topButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) => IconButton(
    tooltip: label,
    onPressed: onPressed,
    icon: Icon(icon, size: 28),
    color: AppColors.textPrimary,
  );

  Widget _smallAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) => TextButton.icon(
    onPressed: onTap,
    icon: Icon(icon, size: 19),
    label: Text(label),
    style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
  );
}

class _FullPlayerProgress extends StatefulWidget {
  const _FullPlayerProgress({required this.cubit, required this.state});

  final TtsCubit cubit;
  final TtsState state;

  @override
  State<_FullPlayerProgress> createState() => _FullPlayerProgressState();
}

class _FullPlayerProgressState extends State<_FullPlayerProgress> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final total = state.totalSentences;
    final max = (total - 1).clamp(0, 1 << 30).toDouble();
    final value =
        _dragValue ??
        (total == 0 ? 0.0 : state.currentIndex.clamp(0, total - 1).toDouble());
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: AppColors.textPrimary,
            inactiveTrackColor: AppColors.textTertiary.withValues(alpha: .45),
            thumbColor: AppColors.textPrimary,
            overlayColor: AppColors.textPrimary.withValues(alpha: .12),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: Slider(
            value: value,
            min: 0,
            max: max,
            onChanged: total > 1 ? (v) => setState(() => _dragValue = v) : null,
            onChangeEnd: total > 1
                ? (v) {
                    setState(() => _dragValue = null);
                    widget.cubit.seek(v.round());
                  }
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                total == 0 ? '0 / 0' : '${value.round() + 1} / $total',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const Text(
                'Tap lyrics to jump to a sentence',
                style: TextStyle(color: AppColors.textTertiary, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MainTransport extends StatelessWidget {
  const _MainTransport({required this.cubit, required this.state});

  final TtsCubit cubit;
  final TtsState state;

  @override
  Widget build(BuildContext context) {
    final enabled = state.available && state.totalSentences > 0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          tooltip: 'Previous sentence',
          onPressed: state.totalSentences > 0 ? () => cubit.skip(-1) : null,
          icon: const Icon(Icons.skip_previous_rounded),
          iconSize: 31,
        ),
        IconButton(
          tooltip: state.isSpeaking
              ? 'Pause reading aloud'
              : 'Play reading aloud',
          onPressed: enabled ? () => cubit.toggle() : null,
          icon: Icon(
            state.isSpeaking ? Icons.pause_rounded : Icons.play_arrow_rounded,
          ),
          iconSize: 42,
          color: AppColors.textPrimary,
          style: IconButton.styleFrom(
            backgroundColor: AppColors.surface2,
            fixedSize: const Size(76, 76),
          ),
        ),
        IconButton(
          tooltip: 'Next sentence',
          onPressed: state.totalSentences > 0 ? () => cubit.skip(1) : null,
          icon: const Icon(Icons.skip_next_rounded),
          iconSize: 31,
        ),
      ],
    );
  }
}

class TtsLyricsPage extends StatefulWidget {
  const TtsLyricsPage({
    super.key,
    required this.cubit,
    required this.bookTitle,
    required this.chapterTitle,
    required this.onOpenSettings,
  });

  final TtsCubit cubit;
  final String bookTitle;
  final String Function() chapterTitle;
  final VoidCallback onOpenSettings;

  @override
  State<TtsLyricsPage> createState() => _TtsLyricsPageState();
}

class _TtsLyricsPageState extends State<TtsLyricsPage> {
  final _scrollController = ScrollController();
  final _itemKeys = <int, GlobalKey>{};
  int _lastScrolledIndex = -1;
  List<TtsSentenceView> _lastSentences = const [];

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleCurrentSentenceIntoView(widget.cubit.state.currentIndex);
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<TtsCubit, TtsState>(
      bloc: widget.cubit,
      listenWhen: (a, b) =>
          a.currentIndex != b.currentIndex || a.sentences != b.sentences,
      listener: (_, state) {
        if (state.sentences != _lastSentences) {
          _lastScrolledIndex = -1;
          _lastSentences = state.sentences;
        }
        _scheduleCurrentSentenceIntoView(state.currentIndex);
      },
      child: BlocBuilder<TtsCubit, TtsState>(
        bloc: widget.cubit,
        builder: (context, state) {
          final viewportHeight = MediaQuery.sizeOf(context).height;
          final sentences = state.sentences;
          _itemKeys.removeWhere((index, _) => index >= sentences.length);
          return Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Back to player',
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.keyboard_arrow_down_rounded),
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
                          tooltip: 'Back to player',
                          onPressed: widget.onOpenSettings,
                          icon: const Icon(Icons.tune_rounded),
                          color: AppColors.textPrimary,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: sentences.isEmpty
                        ? const Center(
                            child: Text(
                              'No transcript available yet',
                              style: TextStyle(color: AppColors.textSecondary),
                            ),
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            padding: EdgeInsets.symmetric(
                              vertical: viewportHeight * .27,
                              horizontal: 28,
                            ),
                            itemCount: sentences.length,
                            itemBuilder: (context, index) {
                              final distance = (index - state.currentIndex)
                                  .abs();
                              final active = distance == 0;
                              final opacity = active
                                  ? 1.0
                                  : (0.64 - distance * .11).clamp(.18, .58);
                              return Semantics(
                                button: true,
                                label: 'Sentence ${index + 1}',
                                child: GestureDetector(
                                  key: _itemKeys.putIfAbsent(
                                    index,
                                    GlobalKey.new,
                                  ),
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => widget.cubit.seek(index),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                      horizontal: 4,
                                    ),
                                    child: Text(
                                      state.sentences[index].text,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: AppColors.textPrimary.withValues(
                                          alpha: opacity,
                                        ),
                                        fontSize: active ? 27 : 23,
                                        height: 1.38,
                                        fontWeight: active
                                            ? FontWeight.w700
                                            : FontWeight.w400,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0),
                          Colors.black.withValues(alpha: .92),
                        ],
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          '${widget.chapterTitle()} · ${widget.bookTitle}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              tooltip: 'Previous sentence',
                              onPressed: sentences.isEmpty
                                  ? null
                                  : () => widget.cubit.skip(-1),
                              icon: const Icon(Icons.skip_previous_rounded),
                            ),
                            IconButton.filled(
                              tooltip: state.isSpeaking
                                  ? 'Pause reading aloud'
                                  : 'Play reading aloud',
                              onPressed: state.available && sentences.isNotEmpty
                                  ? () => widget.cubit.toggle()
                                  : null,
                              icon: Icon(
                                state.isSpeaking
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Next sentence',
                              onPressed: sentences.isEmpty
                                  ? null
                                  : () => widget.cubit.skip(1),
                              icon: const Icon(Icons.skip_next_rounded),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _scheduleCurrentSentenceIntoView(int index) {
    if (index == _lastScrolledIndex) return;
    _lastScrolledIndex = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final itemContext = _itemKeys[index]?.currentContext;
      if (itemContext == null) {
        if (_scrollController.hasClients) {
          final position = _scrollController.position;
          final estimatedOffset = (index * 120.0).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          );
          _scrollController.jumpTo(estimatedOffset);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final context = _itemKeys[index]?.currentContext;
            if (context == null) {
              _lastScrolledIndex = -1;
              return;
            }
            Scrollable.ensureVisible(
              context,
              alignment: .5,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutCubic,
            );
          });
        } else {
          _lastScrolledIndex = -1;
        }
        return;
      }
      Scrollable.ensureVisible(
        itemContext,
        alignment: .5,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    });
  }
}
