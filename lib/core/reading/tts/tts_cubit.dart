import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'sentence_parser.dart';
import 'tts_chapters.dart';
import 'tts_platform.dart';
import 'tts_prefs.dart';
import 'tts_state.dart';

/// Drives text-to-speech for the novel reader.
///
/// Owns the mapping from parsed chapter text to engine events, and is the only
/// place that decides what the reader should highlight. The engine reports which
/// sentence it is speaking; everything else here is bookkeeping around that.
///
/// The platform engine is injected rather than constructed, so the whole
/// controller — including event ordering and resume persistence — is testable
/// against a fake on a machine with no speech engine.
class TtsCubit extends Cubit<TtsState> {
  TtsCubit({
    required TtsPlatform platform,
    required TtsPrefs prefs,
  }) : _platform = platform,
       _prefs = prefs,
       super(
         TtsState(
           voiceName: prefs.voiceName,
           rate: prefs.rate,
           pitch: prefs.pitch,
           sleepTimerMinutes: prefs.sleepTimerMinutes,
           backgroundPlayback: prefs.backgroundPlayback,
         ),
       ) {
    _subscription = _platform.events.listen(_onEvent, onError: _onStreamError);
    unawaited(_initialiseEngine());
  }

  final TtsPlatform _platform;
  final TtsPrefs _prefs;

  StreamSubscription<TtsEngineEvent>? _subscription;

  /// Loads the chapters after the one on screen, when the reader provides a
  /// source. Null in tests and in contexts with no chapter list, which disables
  /// auto-advance rather than failing.
  TtsAutoAdvance? _autoAdvance;

  /// Notification title: the work being read.
  String _workTitle = '';

  /// True while the foreground service is up. Guards the (relatively expensive)
  /// notification refresh so it is not sent on every sentence.
  bool _serviceUp = false;

  /// Parsed sentences of the loaded chapter, kept beside the state so `play`
  /// can build the engine's unit list without re-parsing on every press.
  List<TtsSentenceView> _loaded = const [];

  /// Coalesces resume writes. Persisting on every `sentenceStart` would put
  /// hundreds of Hive writes in a single chapter, which on a low-end phone is
  /// enough to cause visible stutter in the very feature meant to be read
  /// while the page is static.
  Timer? _persistTimer;
  String _pendingChapterId = '';
  int _pendingSentenceIndex = 0;
  bool _hasPendingPosition = false;

  Timer? _sleepTimer;

  Future<void> _initialiseEngine() async {
    emit(state.copyWith(status: TtsStatus.loading, clearError: true));
    try {
      await _platform.init();
    } catch (e) {
      // Only `start` rethrows on the platform side, but a channel can still be
      // torn down underneath us (Activity destroyed mid-init).
      debugPrint('[TtsCubit] engine init failed: $e');
      emit(
        state.copyWith(
          status: TtsStatus.unavailable,
          available: false,
          errorMessage: 'Text-to-speech is unavailable',
        ),
      );
    }
  }

  // ── chapter loading ───────────────────────────────────────────────────────

  /// Parses [html] and makes it the chapter that [play] will speak.
  ///
  /// Does not start speech: the user opens a chapter by scrolling, and starting
  /// audio on every chapter open would be unusable.
  void loadChapter({
    required String bookId,
    required String chapterId,
    required String html,
    bool force = false,
  }) {
    if (chapterId.isEmpty) return;

    if (!force && chapterId == state.chapterId && _loaded.isNotEmpty) {
      // Same chapter re-opened (a rebuild, or returning from a sub-page):
      // keep the parsed sentences and the live position rather than restarting
      // the parse and losing the highlight.
      return;
    }

    final parsed = SentenceParser.parseHtml(html);
    final views = parsed.sentences
        .map(
          (s) => TtsSentenceView(
            index: s.index,
            text: s.text,
            blockIndex: s.blockIndex,
            pauseAfterMs: s.pauseAfterMs,
          ),
        )
        .toList(growable: false);
    _loaded = views;

    emit(
      state.copyWith(
        chapterId: chapterId,
        bookId: bookId,
        sentences: views,
        totalSentences: views.length,
        currentIndex: 0,
        status: state.available ? TtsStatus.idle : state.status,
        clearError: true,
      ),
    );
  }

  /// Adopts a chapter the caller has already segmented against the text it
  /// renders, so sentence offsets can drive a highlight.
  ///
  /// [views] must be in reading order and indexed from 0. Preferred over
  /// [loadChapter] for the on-screen chapter: the reader is the only thing that
  /// knows what its own page actually contains.
  ///
  /// [force] re-adopts a chapter id that is already loaded. Only for the case
  /// where the text under that id has genuinely changed — the reader hiding a
  /// sentence, say — because the point of the same-chapter early return is to
  /// keep a live narration from being reset by a rebuild.
  void adoptChapter({
    required String bookId,
    required String chapterId,
    required List<TtsSentenceView> views,
    bool force = false,
  }) {
    if (chapterId.isEmpty) return;
    if (!force && chapterId == state.chapterId && _loaded.isNotEmpty) return;

    _loaded = views;
    emit(
      state.copyWith(
        chapterId: chapterId,
        bookId: bookId,
        sentences: views,
        totalSentences: views.length,
        currentIndex: 0,
        status: state.available ? TtsStatus.idle : state.status,
        clearError: true,
      ),
    );
  }

  /// Whether [bookId]/[chapterId] has a saved position worth offering.
  TtsResumePoint? resumePointFor(String bookId, String chapterId) {
    final point = _prefs.resumePoint(bookId);
    if (point == null || point.chapterId != chapterId) return null;
    return point;
  }

  /// The sentence to actually resume at, given [point] and the sentences loaded
  /// right now.
  ///
  /// A saved index can be stale: anything that changes which sentences exist
  /// moves every index after the change, and the narration filter removes a
  /// block of note sentences near the top of a chapter, so a point saved before
  /// that now names an earlier sentence. When the saved fingerprint does not
  /// match the sentence at the saved index, the real sentence is looked up by
  /// fingerprint instead, nearest match first so a repeated line of dialogue
  /// still lands on the right occurrence.
  ///
  /// Falls back to the clamped index whenever it cannot do better — an old point
  /// with no fingerprint, a chapter that was edited, or a sentence that is now
  /// filtered out entirely. Resuming a few sentences off is a small annoyance;
  /// refusing to resume at all would be a worse one.
  int resolveResumeIndex(TtsResumePoint point) {
    if (_loaded.isEmpty) return 0;
    final target = point.sentenceIndex.clamp(0, _loaded.length - 1);
    final want = point.fingerprint;
    if (want == null || want.isEmpty) return target;

    if (TtsResumePoint.fingerprintOf(_loaded[target].text) == want) {
      return target;
    }

    var best = -1;
    var bestDistance = 1 << 30;
    for (var i = 0; i < _loaded.length; i++) {
      if (TtsResumePoint.fingerprintOf(_loaded[i].text) != want) continue;
      final distance = (i - target).abs();
      if (distance < bestDistance) {
        best = i;
        bestDistance = distance;
      }
    }
    return best >= 0 ? best : target;
  }

  // ── background narration ──────────────────────────────────────────────────

  /// Supplies the chapter list so narration can continue past the current one,
  /// and starts prefetching the following chapter.
  ///
  /// Called by the reader when it opens. [title] is the work's name, used as the
  /// notification's title.
  void attachChapterSource({
    required TtsAutoAdvance autoAdvance,
    required String workTitle,
  }) {
    _autoAdvance = autoAdvance;
    _workTitle = workTitle;
    unawaited(autoAdvance.ensureCount());
    unawaited(autoAdvance.prefetch());
  }

  /// Detaches the chapter source. Called when the reader closes so a later
  /// completion cannot try to fetch a chapter the user is no longer in.
  void detachChapterSource() {
    _autoAdvance = null;
  }

  /// Moves on to the next chapter, reporting whether it did.
  ///
  /// The reader registers this, and auto-advance cannot do without it: the
  /// reader owns the page, the pagination and the sentence alignment. Loading
  /// the next chapter here and narrating it directly leaves the screen showing
  /// the old chapter, so the highlight is resolved against text the reader is
  /// not displaying and the panel quotes sentences from a page that is not
  /// there — while the voice reads on. Everything about "keep reading" has to
  /// travel the same path a tap on "next chapter" does.
  ///
  /// Deliberately takes no index. The caller has no way to know which chapter
  /// the reader is actually on, and guessing produced a coordinator that
  /// advanced to a chapter nobody had read, or gave up because its guess
  /// landed past the end of a list the reader had not finished loading. "Go to
  /// the next one" is a question only the reader can answer.
  Future<bool> Function()? _navigator;

  /// True while an advance is in flight, so a repeated completion cannot start
  /// a second one.
  bool _advancing = false;

  void attachChapterNavigator(Future<bool> Function() advance) {
    _navigator = advance;
  }

  void detachChapterNavigator() {
    _navigator = null;
  }

  /// Tells the coordinator the reader is now on [index].
  ///
  /// Invalidates the prefetch because it was for the chapter the user just left;
  /// keeping it would mean auto-advance skips a chapter.
  void setChapterIndex(int index) {
    final autoAdvance = _autoAdvance;
    if (autoAdvance == null) return;
    autoAdvance.invalidate();
    autoAdvance.index = index;
    unawaited(autoAdvance.prefetch());
  }

  /// Whether narration should keep going with the screen off.
  Future<void> setBackgroundPlayback(bool enabled) async {
    if (state.backgroundPlayback == enabled) return;
    emit(state.copyWith(backgroundPlayback: enabled));
    await _prefs.setBackgroundPlayback(enabled);
    if (!enabled) await _tearDownService();
  }

  /// Brings the foreground service up, and keeps its notification current.
  ///
  /// The service is what keeps the process alive once the reader screen is
  /// gone, so it is started when narration begins rather than lazily on
  /// backgrounding — by the time the app is backgrounded it is often already too
  /// late to promote a service in time.
  Future<void> _ensureService() async {
    if (!state.backgroundPlayback || _serviceUp) return;
    await _platform.startService(title: _notificationTitle(), sentence: '');
    _serviceUp = true;
  }

  Future<void> _tearDownService() async {
    if (!_serviceUp) return;
    _serviceUp = false;
    await _platform.stopService();
  }

  String _notificationTitle() => _workTitle.isEmpty
      ? 'Reading aloud'
      : 'Reading $_workTitle';

  /// Pushes the sentence being read to the notification.
  ///
  /// Sent on sentence start rather than on every state change: the sentence is
  /// the only part that moves, and a notification rebuild per event would be
  /// wasteful on a long chapter.
  Future<void> _syncServiceSentence() {
    if (!_serviceUp || !state.backgroundPlayback) return Future<void>.value();
    return _platform.updateService(
      title: _notificationTitle(),
      sentence: state.currentSentence?.text ?? '',
    );
  }

  // ── transport ─────────────────────────────────────────────────────────────

  /// Speaks the loaded chapter from [from], defaulting to the current sentence.
  Future<void> play({int? from}) async {
    if (_loaded.isEmpty) {
      emit(
        state.copyWith(
          errorMessage: 'Nothing to read in this chapter',
        ),
      );
      return;
    }

    if (!state.available) {
      // The engine may simply not have finished starting yet; init() is
      // idempotent and reports back through an event, so this is recoverable.
      unawaited(_initialiseEngine());
    }

    final startIndex = (from ?? state.currentIndex).clamp(0, _loaded.length - 1);
    emit(
      state.copyWith(
        status: TtsStatus.speaking,
        currentIndex: startIndex,
        clearError: true,
      ),
    );
    _queuePosition(state.chapterId, startIndex);
    await _ensureService();

    try {
      await _platform.start(units: _units(), startIndex: startIndex);
      await _syncServiceSentence();
      // Warm the following chapter now, so finishing this one does not mean a
      // silent network wait.
      unawaited(_autoAdvance?.prefetch() ?? Future<void>.value());
    } catch (e) {
      debugPrint('[TtsCubit] start failed: $e');
      emit(
        state.copyWith(
          status: TtsStatus.paused,
          errorMessage: 'Could not start reading aloud',
        ),
      );
    }
  }

  Future<void> pause() async {
    if (!state.isSpeaking) return;
    await _platform.pause();
    // The engine reports the index it stopped at; mirror it immediately so the
    // highlight does not lag the pause by a frame.
    emit(state.copyWith(status: TtsStatus.paused));
    await _flushPosition();
  }

  Future<void> resume() async {
    if (state.status != TtsStatus.paused) return;
    emit(state.copyWith(status: TtsStatus.speaking, clearError: true));
    await _platform.resume();
  }

  Future<void> toggle() => state.isSpeaking ? pause() : play();

  /// Drops a session the engine no longer has.
  ///
  /// Narration can end without this cubit being told: the notification's stop
  /// button, a media key, or the app being swiped out of the task switcher,
  /// which stops the service natively (see `TtsService.onTaskRemoved`). While
  /// the app is not on screen nobody sees the difference. Coming back to it is
  /// where it shows — a panel offering pause and a sentence counter for a
  /// voice that has been silent since before the reader reopened the chapter,
  /// and a play button that then appears to do nothing.
  ///
  /// Checks the service rather than assuming: this is the only place that can
  /// tell the two apart, and [TtsPlatform.serviceRunning] is a single channel
  /// round trip on a path that only runs when the reader appears.
  Future<void> syncWithEngine() async {
    if (!state.isActive) return;
    if (await _platform.serviceRunning()) return;
    // The position is kept: the sentence list is still the one on screen, and a
    // reader who presses play expects to carry on from where the voice stopped,
    // not from the top.
    await stop(clearPosition: false);
  }

  /// Stops reading.
  ///
  /// [clearPosition] distinguishes the two reasons to stop. Pressing the stop
  /// button means "I'm done with this chapter" and discards the saved point.
  /// Navigating to another chapter only means the audio belongs to text that is
  /// no longer on screen — the position in the chapter being left is still
  /// somewhere the user may want to come back to, so it is kept.
  Future<void> stop({bool clearPosition = true}) async {
    await _platform.stop();
    _cancelSleepTimer();
    emit(state.copyWith(status: TtsStatus.idle, currentIndex: 0));
    // The prefetched chapter belongs to the run being abandoned.
    _autoAdvance?.invalidate();
    await _tearDownService();
    if (!clearPosition) {
      await _flushPosition();
      return;
    }
    // The pending position is discarded, so cancel the timer before clearing
    // the box: otherwise a queued write could land after the clear and
    // resurrect the point the user just stopped.
    _cancelPendingPosition();
    await _prefs.clearResumePoint(state.bookId);
  }

  /// Jumps to [index] and, if speech is running, restarts from there.
  Future<void> seek(int index) async {
    if (_loaded.isEmpty) return;
    final target = index.clamp(0, _loaded.length - 1);
    emit(state.copyWith(currentIndex: target));
    _queuePosition(state.chapterId, target);

    if (!state.isActive) return;
    // Restart from the new sentence rather than letting the engine finish the
    // current one: seeking and then hearing the old sentence play out is the
    // behaviour that makes a seek control feel broken.
    await play(from: target);
  }

  /// Skips by whole sentences, for the +/- buttons.
  Future<void> skip(int delta) => seek(state.currentIndex + delta);

  // ── settings ──────────────────────────────────────────────────────────────

  Future<void> setVoice(String? name) async {
    emit(
      state.copyWith(
        voiceName: name,
        clearVoiceName: name == null,
        clearError: true,
      ),
    );
    await _platform.setVoice(name);
    await _prefs.setVoiceName(name);
  }

  Future<void> setRate(double rate) async {
    emit(state.copyWith(rate: rate));
    await _platform.setRate(rate);
    await _prefs.setRate(rate);
  }

  Future<void> setPitch(double pitch) async {
    emit(state.copyWith(pitch: pitch));
    await _platform.setPitch(pitch);
    await _prefs.setPitch(pitch);
  }

  Future<List<TtsVoice>> voices() => _platform.voices();

  /// Availability for [tag], for a pre-play warning.
  Future<TtsLanguageStatus> languageStatus(String tag) =>
      _platform.languageStatus(tag);

  // ── sleep timer ───────────────────────────────────────────────────────────

  /// Stops reading after [minutes]; 0 cancels it.
  Future<void> setSleepTimer(int minutes) async {
    _cancelSleepTimer();
    await _prefs.setSleepTimerMinutes(minutes);
    emit(state.copyWith(sleepTimerMinutes: minutes));

    if (minutes <= 0) return;
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      unawaited(_onSleepTimerExpired());
    });
  }

  Future<void> _onSleepTimerExpired() async {
    _sleepTimer = null;
    emit(state.copyWith(sleepTimerMinutes: 0));
    await _prefs.setSleepTimerMinutes(0);
    // Pause rather than stop: falling asleep to a book and finding it reset to
    // the top of the chapter in the morning is the wrong default.
    if (state.isSpeaking) await pause();
  }
  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
  }

  /// Fires a settings write without blocking the caller.
  ///
  /// Every one of these gets its own error handler: a write that fails because
  /// the box closed underneath it (app exiting, a test tearing down) would
  /// otherwise surface as an unhandled async error, which in Flutter is an
  /// unhandled-zone report rather than a caught exception and takes down more
  /// than the write that failed.
  void _fireAndForgetWrite(Future<void> write, String what) {
    unawaited(
      write.catchError(
        (Object e) => debugPrint('[TtsCubit] $what failed: $e'),
      ),
    );
  }

  // ── engine events ─────────────────────────────────────────────────────────

  void _onEvent(TtsEngineEvent event) {
    switch (event) {
      case TtsInitialised(:final ready):
        // Engine availability is independent of any chapter, so this is handled
        // before the chapter guard below. Dropping it while no chapter is open
        // would strand the UI in `loading` and never push the user's saved
        // voice and speed.
        _onInitialised(ready);

      case TtsSentenceStarted(:final index):
        // The engine drains its queue asynchronously, so an event can arrive
        // after the chapter is closed. Acting on it would set a highlight in
        // text that is no longer on screen.
        if (_loaded.isEmpty || index < 0 || index >= _loaded.length) return;
        emit(state.copyWith(currentIndex: index, clearError: true));
        _queuePosition(state.chapterId, index);
        unawaited(_syncServiceSentence());

      case TtsSentenceFinished():
        break;

      case TtsUtteranceFailed(:final index, :final code):
        // A failed sentence is skipped by the engine, which keeps reading, so
        // this is a warning rather than a stop. Silence here would be a lie.
        debugPrint('[TtsCubit] sentence $index failed with code $code');
        emit(state.copyWith(errorMessage: 'Skipped a sentence it could not read'));

      case TtsPaused(:final index):
        if (_loaded.isEmpty) return;
        emit(
          state.copyWith(
            status: TtsStatus.paused,
            currentIndex: index.clamp(0, _loaded.length - 1),
          ),
        );

      case TtsResumed():
        // A resume from the notification or a headset key arrives here, not
        // through this cubit's own methods, so without this the panel kept its
        // play button — looking paused — while the engine was already speaking.
        if (_loaded.isEmpty) return;
        emit(
          state.copyWith(
            status: TtsStatus.speaking,
            currentIndex: state.currentIndex.clamp(0, _loaded.length - 1),
          ),
        );

      case TtsCompleted():
        // Only a session that was actually speaking can have finished. An engine
        // can still emit one after a stop — a queued retry firing late, or a
        // flushed queue draining — and acting on it turns the page and starts
        // reading a chapter the user just stopped. The engine guards against
        // that too; this is the same guard on this side of the channel, because
        // the cost of getting it wrong is the user fighting the app.
        if (!state.isActive) {
          debugPrint(
            '[TtsCubit] ignored a completion for a session that is '
            '${state.status.name}',
          );
          return;
        }
        // The whole chapter was read, so there is nothing left to resume into.
        _cancelPendingPosition();
        _fireAndForgetWrite(
          _prefs.clearResumePoint(state.bookId),
          'clear resume point',
        );
        unawaited(_onChapterCompleted());

      case TtsStopped():
        emit(state.copyWith(status: TtsStatus.idle));
        // The notification's own Stop button acts on the engine directly, so
        // the service is already gone by the time this arrives. Without clearing
        // the flag here, the next play() would believe a foreground service is
        // still up and start narration with nothing keeping the process alive —
        // it would die the moment the app was backgrounded.
        _serviceUp = false;
    }
  }

  void _onInitialised(bool ready) {
    emit(
      state.copyWith(
        available: ready,
        // Readiness clears both `loading` and a previous `unavailable`, but must
        // not stomp a playback that is already running.
        status: ready
            ? switch (state.status) {
                TtsStatus.speaking || TtsStatus.paused => state.status,
                _ => TtsStatus.idle,
              }
            : TtsStatus.unavailable,
        errorMessage: ready
            ? null
            : 'No text-to-speech voice is installed',
        clearError: ready,
      ),
    );
    // Settings must be pushed after the engine exists: it ignores them before
    // initialisation, so applying them at construction time would silently
    // leave the user on default speed.
    if (!ready) return;
    unawaited(_platform.setRate(state.rate));
    unawaited(_platform.setPitch(state.pitch));
    final voice = state.voiceName;
    if (voice != null) unawaited(_platform.setVoice(voice));
  }

  /// Called when the last sentence of a chapter finishes.
  ///
  /// Turns the page and carries on reading. A completion is not an error and
  /// not the end of a reading session: reaching the end of a chapter while
  /// someone is listening is the single most natural moment to start the next
  /// one, and making them reach for the screen breaks the spell.
  ///
  /// ### The page has to turn too
  ///
  /// This used to load the next chapter and narrate it in place, which left the
  /// screen on the old chapter. Three things broke at once, all from the same
  /// cause: the highlight was resolved against the previous chapter's layout,
  /// so it pointed at the wrong words or nowhere; the panel quoted sentences
  /// from a chapter that was not on screen while the voice read them; and the
  /// reader never appeared to move, because nothing had moved it. So the
  /// advance is handed to whoever owns the page and this waits for the result.
  Future<void> _onChapterCompleted() async {
    final autoAdvance = _autoAdvance;
    final navigator = _navigator;

    // Every branch below logs. Auto-advance failing silently was the reason
    // this took three attempts to find: the panel just stops, with nothing to
    // say whether the chapter ran out, the page refused to turn, or the engine
    // never reported completion at all. `adb logcat -s TtsCubit` now answers
    // which, in one line.
    debugPrint(
      '[TtsCubit] chapter completed: source=${autoAdvance != null} '
      'navigator=${navigator != null} advancing=$_advancing '
      'at=${autoAdvance?.index}',
    );

    // No chapter list, or nothing on screen able to turn the page (reader
    // closed, or a bare engine test): this is the end of the session.
    if (autoAdvance == null || navigator == null) {
      debugPrint(
        '[TtsCubit] advance declined: '
        '${autoAdvance == null ? 'no chapter source' : 'nothing can turn the page'}',
      );
      emit(
        state.copyWith(
          status: TtsStatus.idle,
          errorMessage: autoAdvance == null
              ? null
              : 'Read to the end of this chapter',
        ),
      );
      await _tearDownService();
      return;
    }

    // A completion can arrive twice — the engine finishes on the last sentence
    // and again as a flushed queue drains. Two advances racing each other means
    // the second one sees a chapter that is no longer the one it asked for,
    // decides the advance "failed", and tears down the service that the first
    // one had just started. That reads as auto-advance never working at all.
    if (_advancing) {
      debugPrint('[TtsCubit] advance declined: already turning the page');
      return;
    }
    _advancing = true;

    bool moved;
    try {
      moved = await navigator();
    } catch (e, stack) {
      debugPrint('[TtsCubit] could not turn the page: $e\n$stack');
      moved = false;
    } finally {
      _advancing = false;
    }

    debugPrint('[TtsCubit] page turned: $moved');
    if (!moved) {
      // End of the book, or a chapter that would not load. Either way there is
      // nothing to read, and staying in a speaking state with no queue would
      // leave a silent notification running.
      emit(
        state.copyWith(
          status: TtsStatus.idle,
          errorMessage: 'Reached the end of this chapter',
        ),
      );
      await _tearDownService();
      return;
    }

    // The reader has re-segmented the new chapter against the text it actually
    // renders and adopted it, so the queue and the highlight agree again. It has
    // also moved the coordinator's own chapter pointer, since the reader's
    // navigation is what updates it.
    unawaited(autoAdvance.prefetch());

    // From the top: this is the start of a chapter nobody has read yet.
    await play(from: 0);
    debugPrint(
      '[TtsCubit] continued into ${state.chapterId}: '
      '${_loaded.length} sentences, index ${state.currentIndex}',
    );
  }

  void _onStreamError(Object error) {
    debugPrint('[TtsCubit] engine stream error: $error');
    emit(
      state.copyWith(
        status: TtsStatus.unavailable,
        available: false,
        errorMessage: 'Text-to-speech stopped unexpectedly',
      ),
    );
  }

  // ── unit list ─────────────────────────────────────────────────────────────

  /// Engine input starting at [from].
  ///
  /// The remainder of the chapter is sent, not a window, because the engine
  /// refills its own look-ahead queue from the list it was given; sending a
  /// window would stall at the end of it.
  ///
  /// Every sentence of the chapter, in order.
  ///
  /// The **whole** list, not a window from the start index, because the engine
  /// addresses units by their position in the chapter (`units[startIndex]`) and
  /// refills its queue from the sentences after the look-ahead window without
  /// another round trip. Slicing the list to start at the seek position made
  /// `units[startIndex]` out of range for any seek past the halfway point — the
  /// engine could queue nothing, concluded the chapter had finished, and
  /// auto-advance turned the page. Dragging the progress bar to the middle of a
  /// chapter skipped to the next one.
  ///
  /// The last sentence carries no trailing beat, since nothing follows it and
  /// the delay would be dead air before the completion callback.
  List<TtsUnit> _units() => <TtsUnit>[
    for (var i = 0; i < _loaded.length; i++)
      TtsUnit(
        text: _loaded[i].text,
        pauseAfterMs: i == _loaded.length - 1 ? 0 : _loaded[i].pauseAfterMs,
      ),
  ];

  // ── resume persistence ────────────────────────────────────────────────────

  void _queuePosition(String chapterId, int index) {
    if (state.bookId.isEmpty || chapterId.isEmpty) return;
    _pendingChapterId = chapterId;
    _pendingSentenceIndex = index;
    _hasPendingPosition = true;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(seconds: 2), _flushPosition);
  }

  /// Writes any pending position.
  ///
  /// Returns the write so [pause], [stop] and [close] can await it. Firing it
  /// and forgetting means a process death between the user's last sentence and
  /// the write landing loses the position — which is exactly the case this
  /// feature exists to handle.
  Future<void> _flushPosition() {
    _persistTimer?.cancel();
    _persistTimer = null;
    if (!_hasPendingPosition) return Future<void>.value();
    final bookId = state.bookId;
    final chapterId = _pendingChapterId;
    final index = _pendingSentenceIndex;
    _hasPendingPosition = false;
    if (bookId.isEmpty || chapterId.isEmpty) return Future<void>.value();

    // Written alongside the index so the point can be checked against the words
    // it named. Without it, a chapter whose sentence list has since changed
    // resumes at whatever now occupies that number.
    final fingerprint = index >= 0 && index < _loaded.length
        ? TtsResumePoint.fingerprintOf(_loaded[index].text)
        : null;

    return _prefs
        .setResumePoint(bookId, chapterId, index, fingerprint: fingerprint)
        .catchError((Object e) {
      debugPrint('[TtsCubit] resume write failed: $e');
    });
  }

  void _cancelPendingPosition() {
    _persistTimer?.cancel();
    _persistTimer = null;
    _hasPendingPosition = false;
  }

  @override
  Future<void> close() async {
    // Persist on the way out: closing the reader is the most common moment a
    // user stops reading, and losing the position there is the complaint that
    // makes resume features unused.
    await _flushPosition();
    _cancelSleepTimer();
    // Narration deliberately outlives the reader, so the service is left
    // running. Only the chapter source is dropped — a completion after this
    // must not try to fetch a chapter the user is no longer in.
    _autoAdvance = null;
    await _subscription?.cancel();
    await _platform.stop();
    return super.close();
  }
}
