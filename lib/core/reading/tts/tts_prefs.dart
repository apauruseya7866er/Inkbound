import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

/// Where playback should pick up, per book.
///
/// A global "last position" is useless with more than one book open, and
/// resuming to the top of a chapter the user finished yesterday is worse than
/// not resuming at all. Keyed by book so reopening any book lands where that
/// book stopped.
class TtsResumePoint {
  const TtsResumePoint({
    required this.chapterId,
    required this.sentenceIndex,
    this.fingerprint,
  });

  final String chapterId;
  final int sentenceIndex;

  /// A short stable hash of the words this point refers to, or null for a point
  /// saved before fingerprints existed.
  ///
  /// A bare sentence index is only meaningful against the exact list it was
  /// written from. Anything that changes the list moves every index after the
  /// change — and the narration filter does exactly that, by design: an author's
  /// note that used to be sentences 3 to 6 is no longer in the list at all, so
  /// "sentence 12" now names a different sentence. Hashing the text gives the
  /// saved point something to be checked against, and a mismatch is recoverable
  /// instead of silent.
  final String? fingerprint;

  /// True when this point is worth offering to resume from.
  ///
  /// Sentence 0 is excluded deliberately: a book stopped at the very start of a
  /// chapter has nothing to resume, and offering it makes the reader think the
  /// feature is broken.
  bool get isResumable => chapterId.isNotEmpty && sentenceIndex > 0;

  /// A short hash of [text], stable across runs and app restarts.
  ///
  /// FNV-1a rather than [String.hashCode]: Dart does not promise that
  /// `hashCode` returns the same value in a later run, and a fingerprint that
  /// changes when the app restarts cannot verify anything.
  static String fingerprintOf(String text) {
    var hash = 0x811c9dc5;
    for (var i = 0; i < text.length; i++) {
      hash ^= text.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  @override
  String toString() =>
      'TtsResumePoint($chapterId, sentence: $sentenceIndex, fp: $fingerprint)';
}

/// TTS settings, backed by a small untyped Hive box read via `sl<TtsPrefs>()`.
///
/// Speech settings (voice, rate, pitch) are app-wide because a voice choice is a
/// property of the user's ear, not of a book. The resume point is per book.
class TtsPrefs {
  static const String boxName = 'tts_prefs';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely(boxName);
    }
  }

  Box get _box => Hive.box(boxName);

  /// Selected voice name, or null for the system default.
  String? get voiceName {
    final value = _box.get('voiceName') as String?;
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<void> setVoiceName(String? value) => _box.put('voiceName', value);

  /// Speech rate multiplier, [TtsSpeed.min]–[TtsSpeed.max].
  double get rate => _clampRate((_box.get('rate', defaultValue: 1.0) as num).toDouble());

  Future<void> setRate(double value) => _box.put('rate', _clampRate(value));

  /// Pitch multiplier, 0.5–2.0.
  double get pitch => _clampPitch((_box.get('pitch', defaultValue: 1.0) as num).toDouble());

  Future<void> setPitch(double value) => _box.put('pitch', _clampPitch(value));

  /// Stop after this many minutes. 0 means no timer.
  int get sleepTimerMinutes {
    final value = (_box.get('sleepTimerMinutes', defaultValue: 0) as num).toInt();
    return value < 0 ? 0 : value;
  }

  Future<void> setSleepTimerMinutes(int value) =>
      _box.put('sleepTimerMinutes', value < 0 ? 0 : value);

  /// Which step of [TtsSentenceGap] the reader is on.
  ///
  /// Stored as the index rather than the multiplier so a later build that
  /// retunes the steps moves everybody along with it instead of leaving a
  /// "0.55" sitting in the box that no longer means anything.
  int get sentenceGap {
    final value =
        (_box.get('sentenceGap', defaultValue: TtsSentenceGap.defaultIndex)
                as num?)
            ?.toInt() ??
        TtsSentenceGap.defaultIndex;
    return TtsSentenceGap.clampIndex(value);
  }

  Future<void> setSentenceGap(int value) =>
      _box.put('sentenceGap', TtsSentenceGap.clampIndex(value));

  /// Whether narration keeps going with the app backgrounded.
  ///
  /// Defaults to true. Read with a default rather than a stored-on-first-write
  /// flag so an install that predates this setting gets the intended behaviour
  /// without needing a migration.
  bool get backgroundPlayback =>
      _box.get('backgroundPlayback', defaultValue: true) as bool? ?? true;

  Future<void> setBackgroundPlayback(bool value) =>
      _box.put('backgroundPlayback', value);

  /// Saved position for [bookId], or null when there is nothing to resume.
  TtsResumePoint? resumePoint(String bookId) {
    final chapterId = _box.get('resume.chapter.$bookId') as String?;
    final index = (_box.get('resume.sentence.$bookId') as num?)?.toInt();
    if (chapterId == null || index == null) return null;
    final point = TtsResumePoint(
      chapterId: chapterId,
      sentenceIndex: index,
      fingerprint: _box.get('resume.fingerprint.$bookId') as String?,
    );
    return point.isResumable ? point : null;
  }

  Future<void> setResumePoint(
    String bookId,
    String chapterId,
    int sentenceIndex, {
    String? fingerprint,
  }) async {
    if (bookId.isEmpty) return;
    // One write per key rather than a single combined value: a partial write
    // then leaves an old chapter paired with a new index, so the two keys are
    // cleared together when a point is being removed.
    await _box.put('resume.chapter.$bookId', chapterId);
    await _box.put('resume.sentence.$bookId', sentenceIndex);
    // Stored under the same book key as the index it belongs to, and written in
    // the same call, so the two cannot describe different sentences.
    await _box.put('resume.fingerprint.$bookId', fingerprint);
  }

  Future<void> clearResumePoint(String bookId) async {
    if (bookId.isEmpty) return;
    await _box.delete('resume.chapter.$bookId');
    await _box.delete('resume.sentence.$bookId');
    await _box.delete('resume.fingerprint.$bookId');
  }

  /// Clamped to the range the engine accepts, so a corrupted or
  /// hand-edited value cannot produce an unreadable voice.
  double _clampRate(double value) {
    if (value.isNaN || value.isInfinite) return 1.0;
    return value.clamp(TtsSpeed.min, TtsSpeed.max);
  }

  double _clampPitch(double value) {
    if (value.isNaN || value.isInfinite) return 1.0;
    return value.clamp(0.5, 2.0);
  }
}

/// The speech speeds offered by the player's speed button, and how a speed is
/// written on screen.
///
/// ### Why a fixed list, not a slider alone
/// A slider can reach any value, which sounds better until you are tapping at it
/// mid-sentence trying to find "a bit faster". The presets are the values people
/// actually stop at, so the button steps through them and the slider stays for
/// the in-between. Both write the same preference, so they can never disagree
/// about what speed is set.
///
/// ### Rate runs higher than pitch
/// Deliberately: [max] is 3.0 while pitch stops at 2.0. Speech engines stay
/// intelligible well past the point where doubling the pitch is a chipmunk, and
/// these two numbers get clamped in three separate places — here, in the
/// settings slider and in the Kotlin engine — which is exactly how a 3x button
/// ends up silently speaking at 2x.
class TtsSpeed {
  TtsSpeed._();

  /// The preset speeds, slowest first. Tighter spacing at the bottom of the
  /// range, where the difference between 1.7 and 1.8 is the difference between
  /// "comfortable" and "too fast to follow a long sentence".
  static const List<double> presets = <double>[
    1.0, 1.2, 1.3, 1.5, 1.7, 1.8, 2.0, 2.1, 2.3, 2.5, 3.0,
  ];

  /// Slowest rate accepted. Below this even the best engine turns to mumbling.
  static const double min = 0.5;

  /// Fastest rate accepted.
  static const double max = 3.0;

  /// Slack for comparing doubles.
  ///
  /// 1.2 is not storable as exactly 1.2, so cycling from a rate that *is* 1.2
  /// would otherwise compare "greater than itself" as true and hand back 1.2
  /// again — a button that appears to do nothing.
  static const double _epsilon = 1e-6;

  /// The next preset above [current], wrapping round to the slowest.
  ///
  /// Steps up to the next preset rather than snapping to the nearest, so
  /// repeated taps walk up the list predictably. A rate that is not a preset —
  /// set with the slider, say — moves to the first preset above it, which is
  /// the only reading that makes "faster" mean faster.
  static double next(double current) {
    if (current.isNaN) return presets.first;
    for (final value in presets) {
      if (value > current + _epsilon) return value;
    }
    return presets.first;
  }

  /// How [rate] is written on screen: "1x", "1.2x", "3x".
  ///
  /// Trailing ".0" is dropped so the chip stays narrow, and the same formatter
  /// serves the settings sheet so the two places cannot print the same speed
  /// differently.
  static String label(double rate) {
    if (rate.isNaN || rate.isInfinite) return '1x';
    final rounded = (rate * 10).round() / 10;
    final text = rounded == rounded.roundToDouble()
        ? rounded.toStringAsFixed(0)
        : rounded.toStringAsFixed(1);
    return '${text}x';
  }
}

/// How long the gap between two spoken sentences is.
///
/// A multiplier on the parser's punctuation pauses rather than a second set of
/// millisecond values, so the three steps keep the differences the punctuation
/// already encodes — a question still beats a full stop — and only change how
/// wide all of them are.
///
/// ### Why a setting and not just better numbers
/// The tuned pauses in `TtsPause` are one voice on one engine. What sounds
/// natural to the person who tuned them can be dead air to somebody else, and
/// the engine matters as much as the numbers: some ignore the silence entirely,
/// some round it to their own rhythm. A control turns a judgement call into
/// something the reader settles in a second, instead of a guess baked into a
/// release.
class TtsSentenceGap {
  TtsSentenceGap._();

  /// Multiplier per step, tightest first.
  ///
  /// [scales[defaultIndex]] is 1.0, so the default is exactly what the parser
  /// asked for and the setting starts as a no-op rather than as a hidden nudge.
  static const List<double> scales = <double>[0.55, 1.0, 1.7];

  /// What each step is called in the UI, tightest first.
  ///
  /// "Short", "Medium" and "Long" would be describing the gap; these describe
  /// the reading, which is what somebody is actually choosing between.
  static const List<String> labels = <String>['Tight', 'Natural', 'Relaxed'];

  /// The middle step: the tuned pauses, unscaled.
  static const int defaultIndex = 1;

  static const int min = 0;
  static const int max = 2;

  /// The multiplier for [index], clamped.
  ///
  /// Clamped because the stored value is a plain int in an untyped box: a value
  /// written by a build with more steps, or hand-edited, must not index off the
  /// end of [scales] and take the narration down.
  static double scaleAt(int index) =>
      scales[index.clamp(min, max) % scales.length];

  /// The label for [index], clamped the same way as [scaleAt].
  static String labelAt(int index) =>
      labels[index.clamp(min, max) % labels.length];

  /// [index] brought into range, for storing and for the control's position.
  static int clampIndex(int index) => index.clamp(min, max);
}
