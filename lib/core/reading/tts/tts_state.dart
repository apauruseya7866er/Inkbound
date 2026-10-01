import 'package:equatable/equatable.dart';

/// What the reader needs to render the TTS UI.
class TtsState extends Equatable {
  const TtsState({
    this.status = TtsStatus.idle,
    this.currentIndex = 0,
    this.totalSentences = 0,
    this.chapterId = '',
    this.bookId = '',
    this.available = false,
    this.voiceName,
    this.rate = 1.0,
    this.pitch = 1.0,
    this.sleepTimerMinutes = 0,
    this.sentenceGap = 1,
    this.backgroundPlayback = true,
    this.errorMessage,
    this.sentences = const [],
  });

  /// Speech lifecycle. [unavailable] is distinct from [idle]: the device has no
  /// usable engine, and the UI should say so once instead of offering a play
  /// button that silently does nothing.
  final TtsStatus status;

  /// Sentence being spoken, which is what the reader highlights.
  final int currentIndex;
  final int totalSentences;

  final String chapterId;
  final String bookId;

  /// Engine initialised successfully.
  final bool available;

  final String? voiceName;
  final double rate;
  final double pitch;
  final int sleepTimerMinutes;

  /// Which step of the sentence gap is selected, an index into
  /// `TtsSentenceGap.labels`.
  ///
  /// An index rather than a multiplier so the control and the stored value can
  /// never disagree about which step is showing.
  final int sentenceGap;

  /// Whether narration keeps going with the app backgrounded / screen off.
  /// Defaults on: a read-aloud feature that stops when you lock your phone
  /// reads as broken rather than as a setting.
  final bool backgroundPlayback;

  /// Set when speech could not start or a sentence failed. Shown once, then
  /// cleared by the next successful action.
  final String? errorMessage;

  /// Parsed sentences for [chapterId], so the reader can highlight by sentence
  /// without re-parsing. Empty whenever no chapter is loaded.
  final List<TtsSentenceView> sentences;

  bool get isActive =>
      status == TtsStatus.speaking || status == TtsStatus.paused;

  bool get isSpeaking => status == TtsStatus.speaking;

  /// 0..1 progress through the chapter, for the player's progress bar.
  ///
  /// Divided by `totalSentences - 1`, not by `totalSentences`, because
  /// [currentIndex] is a 0-based index while the total is a count: the last
  /// sentence sits at index `total - 1`, so dividing by the count tops out at
  /// `(total - 1) / total` and the bar never reaches the end. That reads as
  /// "the last line of every chapter is never read" — the voice is on it, the
  /// highlight is on it, and the counter disagrees.
  double get progress {
    if (totalSentences <= 1) return 0;
    return (currentIndex / (totalSentences - 1)).clamp(0.0, 1.0);
  }

  /// The sentence currently being spoken, if the chapter is loaded.
  TtsSentenceView? get currentSentence {
    if (sentences.isEmpty) return null;
    if (currentIndex < 0 || currentIndex >= sentences.length) return null;
    return sentences[currentIndex];
  }

  TtsState copyWith({
    TtsStatus? status,
    int? currentIndex,
    int? totalSentences,
    String? chapterId,
    String? bookId,
    bool? available,
    String? voiceName,
    bool clearVoiceName = false,
    double? rate,
    double? pitch,
    int? sleepTimerMinutes,
    int? sentenceGap,
    bool? backgroundPlayback,
    String? errorMessage,
    bool clearError = false,
    List<TtsSentenceView>? sentences,
  }) => TtsState(
    status: status ?? this.status,
    currentIndex: currentIndex ?? this.currentIndex,
    totalSentences: totalSentences ?? this.totalSentences,
    chapterId: chapterId ?? this.chapterId,
    bookId: bookId ?? this.bookId,
    available: available ?? this.available,
    voiceName: clearVoiceName ? null : (voiceName ?? this.voiceName),
    rate: rate ?? this.rate,
    pitch: pitch ?? this.pitch,
    sleepTimerMinutes: sleepTimerMinutes ?? this.sleepTimerMinutes,
    sentenceGap: sentenceGap ?? this.sentenceGap,
    backgroundPlayback: backgroundPlayback ?? this.backgroundPlayback,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    sentences: sentences ?? this.sentences,
  );

  @override
  List<Object?> get props => [
    status,
    currentIndex,
    totalSentences,
    chapterId,
    bookId,
    available,
    voiceName,
    rate,
    pitch,
    sleepTimerMinutes,
    sentenceGap,
    backgroundPlayback,
    errorMessage,
    sentences,
  ];
}

/// Speech lifecycle.
enum TtsStatus {
  /// Nothing loaded, nothing playing.
  idle,

  /// Engine starting, or the chapter is being parsed.
  loading,

  /// Audio playing.
  speaking,

  /// Stopped mid-chapter, position kept.
  paused,

  /// The engine exists but has no voice for this language.
  unavailable,
}

/// The reader-facing view of a parsed sentence.
///
/// A projection of the parser's [TtsSentence] with only what the UI needs, so
/// widgets do not depend on the parser's internals and the highlight cannot
/// accidentally mutate parser state.
class TtsSentenceView extends Equatable {
  const TtsSentenceView({
    required this.index,
    required this.text,
    required this.blockIndex,
    required this.pauseAfterMs,
    this.start = 0,
    this.end = 0,
  });

  final int index;
  final String text;

  /// Paragraph this sentence belongs to. The reader needs it to decide what to
  /// keep on screen in continuous mode.
  final int blockIndex;

  /// Beat to leave after this sentence, as chosen by the parser from its
  /// punctuation. Carried through to the engine rather than recomputed.
  final int pauseAfterMs;

  /// Half-open range within the chapter's *rendered* text.
  ///
  /// Zero-length when the chapter was segmented from HTML rather than from the
  /// rendered token stream, in which case there is nothing to highlight — the
  /// reader still speaks it, it just cannot point at it.
  final int start;
  final int end;

  /// True when this sentence can be highlighted in the page.
  bool get isHighlightable => end > start;

  /// The same sentence with a different gap after it.
  ///
  /// Only the pause varies. Everything else either places the sentence in the
  /// chapter or points at its words on screen, and changing one of those to
  /// adjust a beat would move a highlight.
  TtsSentenceView copyWith({int? pauseAfterMs}) => TtsSentenceView(
        index: index,
        text: text,
        blockIndex: blockIndex,
        pauseAfterMs: pauseAfterMs ?? this.pauseAfterMs,
        start: start,
        end: end,
      );

  @override
  List<Object?> get props => [index, text, blockIndex, pauseAfterMs, start, end];
}
