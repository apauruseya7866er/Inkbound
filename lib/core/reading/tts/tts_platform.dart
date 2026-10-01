import 'dart:async';

/// One sentence handed to the platform engine, plus the beat after it.
///
/// Mirrors `TtsUnit` on the Kotlin side. Deliberately not
/// [TtsSentence]: the engine only needs the text and the pause, and keeping the
/// wire type small means the platform layer does not depend on the parser.
class TtsUnit {
  const TtsUnit({required this.text, required this.pauseAfterMs});

  final String text;
  final int pauseAfterMs;

  Map<String, Object?> toChannel() => {
    'text': text,
    'pauseAfterMs': pauseAfterMs,
  };

  @override
  String toString() => 'TtsUnit("$text", +${pauseAfterMs}ms)';
}

/// A voice the device's speech engine offers.
class TtsVoice {
  const TtsVoice({
    required this.name,
    required this.locale,
    required this.quality,
    required this.requiresNetwork,
  });

  final String name;

  /// BCP-47 tag, e.g. `en-GB`.
  final String locale;

  /// `Voice.QUALITY_*`. Higher is better; 400 is normal.
  final int quality;
  final bool requiresNetwork;

  /// Rough label for the picker, without exposing raw ints to the UI layer.
  String get qualityLabel => switch (quality) {
    >= 500 => 'Excellent',
    >= 400 => 'High',
    >= 300 => 'Normal',
    _ => 'Low',
  };

  factory TtsVoice.fromChannel(Map<Object?, Object?> map) => TtsVoice(
    name: map['name'] as String? ?? '',
    locale: map['locale'] as String? ?? '',
    quality: (map['quality'] as num?)?.toInt() ?? 0,
    requiresNetwork: map['network'] == true,
  );

  @override
  String toString() => 'TtsVoice($name, $locale)';
}

/// Whether a language can actually be spoken on this device.
///
/// Mirrors `TextToSpeech`'s `LANG_*` codes. The distinction that matters to a
/// user is [missingData] (the engine exists but has no voice for that language,
/// and the fix is a download) versus [unsupported] (the engine will never have
/// one), because the settings UI offers a different action for each.
enum TtsLanguageStatus {
  available,
  countryAvailable,
  countryVariantAvailable,

  /// Engine present, voice for this language missing.
  missingData,

  /// The engine cannot speak this language at all.
  unsupported,

  /// The engine is not usable, so availability could not be determined.
  engineError;

  /// True when speech should work, allowing for accent variants.
  bool get canSpeak => switch (this) {
    TtsLanguageStatus.available ||
    TtsLanguageStatus.countryAvailable ||
    TtsLanguageStatus.countryVariantAvailable => true,
    _ => false,
  };

  /// True when a voice exists but only for a different region, which is often
  /// good enough to read with and not worth blocking the user over.
  bool get isApproximate =>
      this == TtsLanguageStatus.countryAvailable ||
      this == TtsLanguageStatus.countryVariantAvailable;

  static TtsLanguageStatus fromCode(int code) => switch (code) {
    0 => TtsLanguageStatus.available,
    1 => TtsLanguageStatus.countryAvailable,
    2 => TtsLanguageStatus.countryVariantAvailable,
    -1 => TtsLanguageStatus.missingData,
    -2 => TtsLanguageStatus.unsupported,
    _ => TtsLanguageStatus.engineError,
  };
}

/// Something the engine reported.
///
/// A sealed hierarchy rather than a flag field, so a `switch` over events is
/// checked by the compiler: adding a new event without handling it in the
/// cubit becomes a build error instead of a silently ignored state.
sealed class TtsEngineEvent {
  const TtsEngineEvent();
}

/// The engine finished starting, or failed to.
class TtsInitialised extends TtsEngineEvent {
  const TtsInitialised({required this.ready});
  final bool ready;
}

/// A sentence began, and is the one to highlight.
class TtsSentenceStarted extends TtsEngineEvent {
  const TtsSentenceStarted(this.index);
  final int index;
}

/// A sentence finished speaking.
class TtsSentenceFinished extends TtsEngineEvent {
  const TtsSentenceFinished(this.index);
  final int index;
}

/// A sentence could not be spoken. The engine skips it and carries on.
class TtsUtteranceFailed extends TtsEngineEvent {
  const TtsUtteranceFailed(this.index, this.code);
  final int index;
  final int code;
}

class TtsPaused extends TtsEngineEvent {
  const TtsPaused(this.index);
  final int index;
}

/// Playback resumed, from outside the app.
///
/// The counterpart to [TtsPaused], and the one that was missing: resuming from
/// the notification or a headset key drives the engine directly, and the engine
/// had no way to say so. Dart went on showing "paused" — the play button stayed
/// on screen while audio was already playing, which reads as a broken control
/// rather than as stale state.
class TtsResumed extends TtsEngineEvent {
  const TtsResumed();
}

/// The last sentence of the chapter was reached.
class TtsCompleted extends TtsEngineEvent {
  const TtsCompleted();
}

/// The user stopped playback.
class TtsStopped extends TtsEngineEvent {
  const TtsStopped();
}

/// The platform speech engine.
///
/// An interface so the controller and the UI can be tested without a device:
/// the method-channel implementation is the only class that needs Android, and
/// everything above it can be exercised with a fake.
abstract class TtsPlatform {
  /// Engine events. Broadcast so the cubit is the only subscriber and a late
  /// listener does not miss the events already in flight.
  Stream<TtsEngineEvent> get events;

  /// Starts the engine. Safe to call more than once.
  Future<void> init();

  /// Speaks [units] beginning at [startIndex].
  Future<void> start({required List<TtsUnit> units, required int startIndex});

  /// Stops and forgets the queue.
  Future<void> stop();

  /// Stops but keeps the position, so [resume] continues from it.
  Future<void> pause();

  Future<void> resume();

  /// Selects a voice by [TtsVoice.name]; null restores the system default.
  Future<void> setVoice(String? name);

  Future<void> setRate(double rate);

  Future<void> setPitch(double pitch);

  /// Scales every gap between sentences by [scale], where 1.0 is exactly what
  /// the units asked for.
  ///
  /// Held by the engine rather than folded into the unit list on the way in, so
  /// that changing it while narration is running applies to the sentences the
  /// engine has not queued yet — the ones a second from now — instead of only
  /// taking effect on the next chapter.
  Future<void> setPauseScale(double scale);

  /// Every installed voice, for the picker.
  Future<List<TtsVoice>> voices();

  /// Availability for a BCP-47 [tag].
  Future<TtsLanguageStatus> languageStatus(String tag);

  /// Device locale, used to pick a sensible default voice.
  Future<String> defaultLocale();

  // ── foreground service ──
  //
  // Speech has to survive the reader screen closing. The engine lives in the app
  // process, and that process is killed when the app is swiped away — so a
  // foreground service is what actually keeps narration audible. It is also
  // where the lockscreen transport lives.

  /// Starts the foreground service and shows its notification.
  Future<void> startService({
    required String title,
    required String sentence,
  });

  /// Refreshes the notification, e.g. as the sentence being read changes.
  ///
  /// A no-op when the service is not running.
  Future<void> updateService({
    required String title,
    required String sentence,
  });

  /// Stops the service and removes the notification.
  Future<void> stopService();

  /// Whether the foreground service is currently running.
  Future<bool> serviceRunning();
}
