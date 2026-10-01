import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/reading/tts/tts_chapters.dart';
import 'package:watch_app/core/reading/tts/tts_cubit.dart';
import 'package:watch_app/core/reading/tts/tts_platform.dart';
import 'package:watch_app/core/reading/tts/tts_prefs.dart';
import 'package:watch_app/core/reading/tts/tts_state.dart';
import 'package:watch_app/core/reading/tts/sentence_parser.dart';

/// A stand-in for the platform engine.
///
/// Lets the controller's behaviour be tested on a machine with no speech
/// engine: event ordering, resume persistence and the pause/seek semantics are
/// all reachable by pushing events and inspecting recorded calls.
class FakeTtsPlatform implements TtsPlatform {
  final StreamController<TtsEngineEvent> _events =
      StreamController<TtsEngineEvent>.broadcast();

  List<TtsUnit> lastUnits = const [];
  int lastStartIndex = -1;
  int startCalls = 0;
  int stopCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int initCalls = 0;
  String? lastVoice;
  bool voiceWasSet = false;
  double? lastRate;
  double? lastPitch;
  bool failOnStart = false;
  List<TtsVoice> voiceList = const [];
  String locale = 'en-US';
  TtsLanguageStatus language = TtsLanguageStatus.available;

  @override
  Stream<TtsEngineEvent> get events => _events.stream;

  /// Pushes an engine event, as the native side would.
  void emit(TtsEngineEvent event) => _events.add(event);

  /// Simulates the engine finishing initialising.
  void becomeReady({bool ready = true}) =>
      emit(TtsInitialised(ready: ready));

  /// Simulates the native stream failing.
  void emitError(Object error) => _events.addError(error);

  @override
  Future<void> init() async => initCalls++;

  @override
  Future<void> start({
    required List<TtsUnit> units,
    required int startIndex,
  }) async {
    if (failOnStart) throw Exception('engine refused');
    startCalls++;
    lastUnits = units;
    lastStartIndex = startIndex;
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> pause() async => pauseCalls++;

  @override
  Future<void> resume() async => resumeCalls++;

  @override
  Future<void> setVoice(String? name) async {
    lastVoice = name;
    voiceWasSet = true;
  }

  @override
  Future<void> setRate(double rate) async => lastRate = rate;

  @override
  Future<void> setPitch(double pitch) async => lastPitch = pitch;

  /// Every value the cubit has pushed, in order: the setting is re-asserted on
  /// each start, so "the last one" and "only one" are different questions.
  final List<double> pauseScales = <double>[];

  @override
  Future<void> setPauseScale(double scale) async => pauseScales.add(scale);

  @override
  Future<List<TtsVoice>> voices() async => voiceList;

  @override
  Future<TtsLanguageStatus> languageStatus(String tag) async => language;

  @override
  Future<String> defaultLocale() async => locale;

  // ── foreground service ──
  int startServiceCalls = 0;
  int updateServiceCalls = 0;
  int stopServiceCalls = 0;
  bool serviceUp = false;
  String lastServiceTitle = '';
  String lastServiceSentence = '';

  @override
  Future<void> startService({
    required String title,
    required String sentence,
  }) async {
    startServiceCalls++;
    serviceUp = true;
    lastServiceTitle = title;
    lastServiceSentence = sentence;
  }

  @override
  Future<void> updateService({
    required String title,
    required String sentence,
  }) async {
    updateServiceCalls++;
    lastServiceTitle = title;
    lastServiceSentence = sentence;
  }

  @override
  Future<void> stopService() async {
    stopServiceCalls++;
    serviceUp = false;
  }

  @override
  Future<bool> serviceRunning() async => serviceUp;

  Future<void> dispose() => _events.close();
}

const _chapterHtml = '<p>First sentence here. Second one follows.</p>'
    '<p>Third sentence now. Fourth closes it.</p>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late FakeTtsPlatform platform;
  late TtsPrefs prefs;

  Future<TtsCubit> build() async {
    final cubit = TtsCubit(platform: platform, prefs: prefs);
    // The constructor kicks off init; let it settle so tests start from a known
    // point rather than racing the engine.
    await Future<void>.delayed(Duration.zero);
    return cubit;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tts_cubit_test_');
    Hive.init(tempDir.path);
    await TtsPrefs.init();
    prefs = TtsPrefs();
    platform = FakeTtsPlatform();
  });

  tearDown(() async {
    await platform.dispose();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('engine initialisation', () {
    test('starts idle and asks the engine to initialise', () async {
      final cubit = await build();
      expect(platform.initCalls, 1);
      expect(cubit.state.status, TtsStatus.loading);
      await cubit.close();
    });

    test('becomes available when the engine reports ready', () async {
      final cubit = await build();
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.available, isTrue);
      expect(cubit.state.status, TtsStatus.idle);
      await cubit.close();
    });

    test('re-pushes saved settings once the engine is ready', () async {
      await prefs.setRate(1.4);
      await prefs.setPitch(0.8);
      await prefs.setVoiceName('en-GB-x');
      platform = FakeTtsPlatform();
      final cubit = await build();

      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);

      // Settings sent before the engine exists are ignored by the platform, so
      // they must be re-applied or the user's choices silently do nothing.
      expect(platform.lastRate, 1.4);
      expect(platform.lastPitch, 0.8);
      expect(platform.lastVoice, 'en-GB-x');
      await cubit.close();
    });

    test('reports unavailable when the engine has no voice', () async {
      final cubit = await build();
      platform.becomeReady(ready: false);
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.available, isFalse);
      expect(cubit.state.status, TtsStatus.unavailable);
      expect(cubit.state.errorMessage, isNotNull);
      await cubit.close();
    });

    test('recovers from unavailable to idle when an engine appears', () async {
      final cubit = await build();
      platform.becomeReady(ready: false);
      await Future<void>.delayed(Duration.zero);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.status, TtsStatus.idle);
      await cubit.close();
    });
  });

  group('chapter loading', () {
    test('parses the chapter into sentences', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      expect(cubit.state.totalSentences, 4);
      expect(cubit.state.chapterId, 'c1');
      expect(cubit.state.bookId, 'b1');
      expect(cubit.state.sentences, hasLength(4));
      expect(cubit.state.sentences.first.text, 'First sentence here.');
      await cubit.close();
    });

    test('does not speak on load', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      expect(platform.startCalls, 0);
      await cubit.close();
    });

    test('reloading the same chapter keeps the position', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      platform.emit(const TtsSentenceStarted(2));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.currentIndex, 2);

      // A rebuild re-runs load; the highlight must not jump back to the top.
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      expect(cubit.state.currentIndex, 2);
      expect(cubit.state.totalSentences, 4);
      await cubit.close();
    });

    test('a new chapter resets the position', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      platform.emit(const TtsSentenceStarted(3));
      await Future<void>.delayed(Duration.zero);

      cubit.loadChapter(bookId: 'b1', chapterId: 'c2', html: _chapterHtml);
      expect(cubit.state.currentIndex, 0);
      expect(cubit.state.chapterId, 'c2');
      await cubit.close();
    });

    test('an empty chapter loads without sentences', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: '<p></p>');
      expect(cubit.state.totalSentences, 0);
      await cubit.close();
    });
  });

  group('playback', () {
    test('sends every sentence from the start with its pause', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);

      await cubit.play();
      expect(platform.startCalls, 1);
      expect(platform.lastStartIndex, 0);
      expect(platform.lastUnits, hasLength(4));
      expect(platform.lastUnits.first.text, 'First sentence here.');
      expect(platform.lastUnits.first.pauseAfterMs, greaterThan(0));
      expect(cubit.state.isSpeaking, isTrue);
      await cubit.close();
    });

    test('the final sentence carries no trailing pause', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();

      // A beat after the last sentence would be dead air before completion.
      expect(platform.lastUnits.last.pauseAfterMs, 0);
      expect(
        platform.lastUnits[platform.lastUnits.length - 2].pauseAfterMs,
        greaterThan(0),
      );
      await cubit.close();
    });

    test('resuming mid-chapter still addresses the whole chapter', () async {
      // This used to assert the opposite — that resuming sent *only* the
      // remainder, alongside a startIndex that counted from the chapter start.
      // Those two are incompatible: the engine reads `units[startIndex]`, so a
      // list beginning at sentence 2 could not be indexed with 2. It happened
      // to work while the remainder was longer than the offset, which is why it
      // only broke from the halfway point of a chapter onwards.
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);

      await cubit.play(from: 2);
      expect(platform.lastStartIndex, 2);
      expect(platform.lastUnits, hasLength(4));
      expect(
        platform.lastUnits[2].text,
        'Third sentence now.',
        reason: 'the engine must be able to read the sentence it was asked for',
      );
      await cubit.close();
    });

    test('play with nothing loaded reports an error and does not call out',
        () async {
      final cubit = await build();
      await cubit.play();
      expect(platform.startCalls, 0);
      expect(cubit.state.errorMessage, isNotNull);
      await cubit.close();
    });

    test('an engine that refuses to start surfaces an error', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      platform.failOnStart = true;

      await cubit.play();
      expect(cubit.state.isSpeaking, isFalse);
      expect(cubit.state.errorMessage, isNotNull);
      await cubit.close();
    });

    test('an out-of-range index is clamped rather than crashing', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);

      await cubit.play(from: 999);
      expect(platform.lastStartIndex, 3);
      await cubit.close();
    });

    test('a negative index is clamped rather than crashing', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);

      await cubit.play(from: -5);
      expect(platform.lastStartIndex, 0);
      await cubit.close();
    });
  });

  group('transport controls', () {
    test('pause keeps the position', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();
      platform.emit(const TtsSentenceStarted(1));
      await Future<void>.delayed(Duration.zero);

      await cubit.pause();
      expect(platform.pauseCalls, 1);
      expect(cubit.state.status, TtsStatus.paused);
      expect(cubit.state.currentIndex, 1);
      await cubit.close();
    });

    test('pause does nothing when not speaking', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.pause();
      expect(platform.pauseCalls, 0);
      await cubit.close();
    });

    test('resume continues from the paused position', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();
      platform.emit(const TtsPaused(2));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.status, TtsStatus.paused);

      await cubit.resume();
      expect(platform.resumeCalls, 1);
      expect(cubit.state.isSpeaking, isTrue);
      await cubit.close();
    });

    test('resume does nothing when not paused', () async {
      final cubit = await build();
      await cubit.resume();
      expect(platform.resumeCalls, 0);
      await cubit.close();
    });

    test('a resume from outside the app clears the paused state', () async {
      // The notification and a headset key drive the engine directly, so the
      // only way Dart learns about it is the engine's own event. Without it the
      // panel kept showing a play button while audio was already running.
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();
      platform.emit(const TtsPaused(2));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.status, TtsStatus.paused);

      platform.emit(const TtsResumed());
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.status, TtsStatus.speaking);
      expect(cubit.state.isSpeaking, isTrue);
      // The position is the engine's to report; this event is only about state.
      expect(cubit.state.currentIndex, 2);
      await cubit.close();
    });


    test('toggle flips between playing and paused', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);

      await cubit.toggle();
      expect(cubit.state.isSpeaking, isTrue);
      await cubit.toggle();
      expect(cubit.state.status, TtsStatus.paused);
      await cubit.close();
    });

    test('stop clears the position and the saved point', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();
      platform.emit(const TtsSentenceStarted(2));
      await Future<void>.delayed(Duration.zero);
      await cubit.pause();
      expect(prefs.resumePoint('b1'), isNotNull);

      await cubit.stop();
      expect(platform.stopCalls, 1);
      expect(cubit.state.status, TtsStatus.idle);
      expect(cubit.state.currentIndex, 0);
      expect(prefs.resumePoint('b1'), isNull);
      await cubit.close();
    });
  });

  group('seeking', () {
    test('the whole chapter is sent, so any seek position can queue', () async {
      // The engine addresses units by their position in the chapter, so a list
      // sliced to start at the seek position made `units[startIndex]` out of
      // range from the halfway point on. Nothing could queue, the engine read
      // that as "chapter finished", and auto-advance turned the page — dragging
      // the progress bar past the middle skipped to the next chapter.
      final cubit = await build();
      const sentences = 40;
      final html = '<p>${List.generate(
        sentences,
        (i) => 'Sentence number $i stands here.',
      ).join(' ')}</p>';
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: html);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();

      expect(cubit.state.totalSentences, sentences);

      for (final target in [sentences ~/ 2, (sentences * 3) ~/ 4, sentences - 2]) {
        await cubit.seek(target);
        expect(
          platform.lastUnits.length,
          cubit.state.totalSentences,
          reason: 'seeking to $target sent a shortened list',
        );
        // The engine reads units[startIndex]; it must be the sentence asked for.
        expect(
          platform.lastUnits[platform.lastStartIndex].text,
          cubit.state.sentences[target].text,
          reason: 'seek to $target queued the wrong sentence',
        );
      }
      await cubit.close();
    });

    test('seek while speaking restarts from the target', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();

      await cubit.seek(3);
      expect(cubit.state.currentIndex, 3);
      // Restarting, not waiting for the current sentence to finish.
      expect(platform.startCalls, 2);
      expect(platform.lastStartIndex, 3);
      await cubit.close();
    });

    test('seek while idle does not start speech', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);

      await cubit.seek(2);
      expect(cubit.state.currentIndex, 2);
      expect(platform.startCalls, 0);
      await cubit.close();
    });

    test('skip moves relative to the current sentence', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);

      await cubit.skip(2);
      expect(cubit.state.currentIndex, 2);
      await cubit.skip(-1);
      expect(cubit.state.currentIndex, 1);
      await cubit.close();
    });

    test('seeking past the end clamps to the last sentence', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.seek(99);
      expect(cubit.state.currentIndex, 3);
      await cubit.close();
    });

    test('seeking with nothing loaded is a no-op', () async {
      final cubit = await build();
      await cubit.seek(2);
      expect(platform.startCalls, 0);
      await cubit.close();
    });
  });

  group('resume persistence', () {
    test('a sentence event alone does not write on every sentence', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();

      platform.emit(const TtsSentenceStarted(2));
      await Future<void>.delayed(Duration.zero);

      // Coalesced, not written per sentence: hundreds of Hive writes in one
      // chapter would stutter the reading experience it is meant to accompany.
      expect(prefs.resumePoint('b1'), isNull);
      await cubit.close();
    });

    test('pausing flushes the position', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();
      platform.emit(const TtsSentenceStarted(3));
      await Future<void>.delayed(Duration.zero);

      await cubit.pause();
      expect(prefs.resumePoint('b1')?.sentenceIndex, 3);
      expect(prefs.resumePoint('b1')?.chapterId, 'c1');
      await cubit.close();
    });

    test('closing the reader flushes the position', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();
      platform.emit(const TtsSentenceStarted(2));
      await Future<void>.delayed(Duration.zero);

      await cubit.close();
      expect(prefs.resumePoint('b1')?.sentenceIndex, 2);
    });

    test('resumePointFor only offers a matching chapter', () async {
      await prefs.setResumePoint('b1', 'c1', 5);
      final cubit = await build();
      expect(cubit.resumePointFor('b1', 'c1')?.sentenceIndex, 5);
      expect(cubit.resumePointFor('b1', 'c2'), isNull);
      expect(cubit.resumePointFor('b2', 'c1'), isNull);
      await cubit.close();
    });

    test('completing a chapter clears the saved point', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();
      platform.emit(const TtsSentenceStarted(3));
      await Future<void>.delayed(Duration.zero);
      await cubit.pause();
      expect(prefs.resumePoint('b1'), isNotNull);

      platform.emit(const TtsCompleted());
      // The handler cannot await inside a stream listener, so let the box write
      // land before asserting on it.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(cubit.state.status, TtsStatus.idle);
      // Reading the whole chapter means there is nothing left to resume into.
      expect(prefs.resumePoint('b1'), isNull);
      await cubit.close();
    });
  });

  group('engine event handling', () {
    test('events are ignored when no chapter is loaded', () async {
      final cubit = await build();
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      // The engine drains its queue asynchronously; a late event must not set a
      // highlight in a chapter that is no longer open.
      platform.emit(const TtsSentenceStarted(3));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.currentIndex, 0);
      await cubit.close();
    });

    test('an out-of-range sentence index is ignored', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      platform.emit(const TtsSentenceStarted(99));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.currentIndex, 0);
      await cubit.close();
    });

    test('a failed sentence warns but keeps reading', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();

      platform.emit(const TtsUtteranceFailed(1, -3));
      await Future<void>.delayed(Duration.zero);

      // The engine skips and continues, so stopping here would be a lie.
      expect(cubit.state.isSpeaking, isTrue);
      expect(cubit.state.errorMessage, isNotNull);
      await cubit.close();
    });

    test('a new sentence clears the previous error', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();
      platform.emit(const TtsUtteranceFailed(1, -3));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.errorMessage, isNotNull);

      platform.emit(const TtsSentenceStarted(2));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.errorMessage, isNull);
      await cubit.close();
    });

    test('a stream error marks the engine unavailable', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);

      platform.emitError(Exception('engine died'));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.available, isFalse);
      expect(cubit.state.status, TtsStatus.unavailable);
      await cubit.close();
    });

    test('a stop event returns to idle', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();
      platform.emit(const TtsStopped());
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.status, TtsStatus.idle);
      await cubit.close();
    });
  });

  group('settings', () {
    test('voice is applied and remembered', () async {
      final cubit = await build();
      await cubit.setVoice('en-AU-voice');
      expect(platform.lastVoice, 'en-AU-voice');
      expect(prefs.voiceName, 'en-AU-voice');
      expect(cubit.state.voiceName, 'en-AU-voice');
      await cubit.close();
    });

    test('clearing the voice restores the default', () async {
      final cubit = await build();
      await cubit.setVoice('en-AU-voice');
      await cubit.setVoice(null);
      expect(platform.lastVoice, isNull);
      expect(prefs.voiceName, isNull);
      expect(cubit.state.voiceName, isNull);
      await cubit.close();
    });

    test('rate and pitch are applied and remembered', () async {
      final cubit = await build();
      await cubit.setRate(1.25);
      await cubit.setPitch(0.9);
      expect(platform.lastRate, 1.25);
      expect(platform.lastPitch, 0.9);
      expect(prefs.rate, 1.25);
      expect(prefs.pitch, 0.9);
      await cubit.close();
    });

    test('voices come from the platform', () async {
      platform.voiceList = const [
        TtsVoice(
          name: 'v1',
          locale: 'en-GB',
          quality: 500,
          requiresNetwork: false,
        ),
      ];
      final cubit = await build();
      expect(await cubit.voices(), hasLength(1));
      await cubit.close();
    });
  });

  // The gap is what stops the narration sounding like a machine reading a list,
  // and these cover the two halves of it: the paragraph beat is decided in Dart
  // from the sentence list, while the reader's chosen width is applied by the
  // engine so it can change without re-sending the chapter.
  group('the gap between sentences', () {
    test('the last sentence of a paragraph gets the longer beat', () async {
      final cubit = await build();
      cubit.loadChapter(
        bookId: 'b1',
        chapterId: 'c1',
        html: '<p>One here. Two here.</p><p>Three here. Four here.</p>',
      );

      final s = cubit.state.sentences;
      expect(s, hasLength(4));
      // Sentence 1 ends its paragraph, so it beats plain sentence 0 by exactly
      // the paragraph amount on top of the punctuation's own.
      expect(s[1].pauseAfterMs, s[0].pauseAfterMs + TtsPause.paragraph);
      // Sentence 2 is mid-paragraph again.
      expect(s[2].pauseAfterMs, s[0].pauseAfterMs);
      await cubit.close();
    });

    test('the paragraph beat is added on the reader path too', () async {
      // The reader does not use loadChapter: it adopts its own segmentation so
      // the highlight lines up. The beat has to survive that door as well, or
      // it only exists for the background narration nobody listens to.
      final cubit = await build();
      cubit.adoptChapter(
        bookId: 'b1',
        chapterId: 'c1',
        views: const [
          TtsSentenceView(
            index: 0,
            text: 'One here.',
            blockIndex: 0,
            pauseAfterMs: TtsPause.normal,
          ),
          TtsSentenceView(
            index: 1,
            text: 'Two here.',
            blockIndex: 1,
            pauseAfterMs: TtsPause.normal,
          ),
        ],
      );

      final s = cubit.state.sentences;
      expect(s[0].pauseAfterMs, TtsPause.normal + TtsPause.paragraph);
      expect(s[1].pauseAfterMs, TtsPause.normal);
      await cubit.close();
    });

    test('the final sentence of the chapter keeps the plain beat', () async {
      // Nothing follows it, so the beat would be dead air before the engine
      // reports the chapter finished.
      final cubit = await build();
      cubit.loadChapter(
        bookId: 'b1',
        chapterId: 'c1',
        html: '<p>Only paragraph here. And more.</p>',
      );

      expect(
        cubit.state.sentences.last.pauseAfterMs,
        TtsPause.normal,
      );
      await cubit.close();
    });

    test('a note block the narration drops leaves the beats alone', () async {
      // The break is decided by block index, and a block the narrator skips is
      // not a paragraph anybody heard the end of. The two sentences that are
      // left are still one paragraph, so neither picks up a break — otherwise
      // every chapter with a translator's tag would gain a pause where nothing
      // was said.
      final cubit = await build();
      cubit.loadChapter(
        bookId: 'b1',
        chapterId: 'c1',
        html: '<p>One here. Two here.</p><p>[TN: BornToBe]</p>',
      );

      final s = cubit.state.sentences;
      expect(s, hasLength(2));
      expect(s[0].pauseAfterMs, TtsPause.normal);
      expect(s[1].pauseAfterMs, TtsPause.normal);
      await cubit.close();
    });

    test('choosing a step sends its multiplier and is remembered', () async {
      final cubit = await build();
      await cubit.setSentenceGap(TtsSentenceGap.max);

      expect(platform.pauseScales.last, TtsSentenceGap.scales.last);
      expect(cubit.state.sentenceGap, TtsSentenceGap.max);
      expect(prefs.sentenceGap, TtsSentenceGap.max);
      await cubit.close();
    });

    test('a step out of range is clamped rather than throwing', () async {
      final cubit = await build();
      await cubit.setSentenceGap(99);

      expect(cubit.state.sentenceGap, TtsSentenceGap.max);
      expect(prefs.sentenceGap, TtsSentenceGap.max);
      await cubit.close();
    });

    test('picking the step already chosen does not talk to the engine', () async {
      final cubit = await build();
      await cubit.setSentenceGap(TtsSentenceGap.min);
      final after = platform.pauseScales.length;

      await cubit.setSentenceGap(TtsSentenceGap.min);

      expect(platform.pauseScales, hasLength(after));
      await cubit.close();
    });

    test('the saved step is restored and re-sent once the engine is ready',
        () async {
      await prefs.setSentenceGap(TtsSentenceGap.max);
      platform = FakeTtsPlatform();
      final cubit = await build();

      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.sentenceGap, TtsSentenceGap.max);
      expect(platform.pauseScales.last, TtsSentenceGap.scales.last);
      await cubit.close();
    });

    test('starting narration re-asserts the scale', () async {
      // The service is a separate component the system can tear down and rebuild;
      // a fresh one starts at 1.0 and would quietly narrate with the wrong gap
      // until the setting was touched again.
      final cubit = await build();
      await cubit.setSentenceGap(TtsSentenceGap.max);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      final before = platform.pauseScales.length;

      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      await cubit.play();

      expect(platform.pauseScales.length, greaterThan(before));
      expect(platform.pauseScales.last, TtsSentenceGap.scales.last);
      await cubit.close();
    });
  });

  group('sleep timer', () {
    test('setting it is remembered', () async {
      final cubit = await build();
      await cubit.setSleepTimer(15);
      expect(cubit.state.sleepTimerMinutes, 15);
      expect(prefs.sleepTimerMinutes, 15);
      await cubit.setSleepTimer(0);
      await cubit.close();
    });
  });

  group('background playback service', () {
    test('play brings the service up', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);

      await cubit.play();
      // Started when narration begins, not lazily on backgrounding: by then it
      // is often too late to promote a service in time.
      expect(platform.startServiceCalls, 1);
      expect(platform.serviceUp, isTrue);
      await cubit.close();
    });

    test('the notification shows the work and the sentence', () async {
      final cubit = await build();
      cubit.attachChapterSource(
        autoAdvance: TtsAutoAdvance(
          source: _FakeChapterSource(),
          index: 0,
        ),
        workTitle: 'A Wizard of Earthsea',
      );
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();

      platform.emit(const TtsSentenceStarted(1));
      await Future<void>.delayed(Duration.zero);

      expect(platform.lastServiceTitle, contains('A Wizard of Earthsea'));
      expect(platform.lastServiceSentence, 'Second one follows.');
      await cubit.close();
    });

    test('the notification updates as sentences advance', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();
      final afterStart = platform.updateServiceCalls;

      platform.emit(const TtsSentenceStarted(3));
      await Future<void>.delayed(Duration.zero);
      expect(platform.updateServiceCalls, greaterThan(afterStart));
      expect(platform.lastServiceSentence, 'Fourth closes it.');
      await cubit.close();
    });

    test('stop takes the service down', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();
      await cubit.stop();
      expect(platform.stopServiceCalls, 1);
      expect(platform.serviceUp, isFalse);
      await cubit.close();
    });

    test('a chapter change takes the service down but keeps the position',
        () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();
      platform.emit(const TtsSentenceStarted(2));
      await Future<void>.delayed(Duration.zero);

      await cubit.stop(clearPosition: false);
      expect(platform.stopServiceCalls, 1);
      expect(prefs.resumePoint('b1')?.sentenceIndex, 2);
      await cubit.close();
    });

    // Narration can end without this cubit hearing about it — the notification,
    // a media key, or the app being swiped out of the task switcher, which stops
    // the service natively. Returning to the reader must not leave a panel
    // offering to pause a voice that stopped minutes ago.
    group('syncWithEngine', () {
      test('drops a session the service no longer has', () async {
        final cubit = await build();
        cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
        platform.becomeReady();
        await Future<void>.delayed(Duration.zero);
        await cubit.play();
        platform.emit(const TtsSentenceStarted(2));
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.isActive, isTrue);

        // The service died behind our back.
        platform.serviceUp = false;
        await cubit.syncWithEngine();

        expect(cubit.state.isActive, isFalse);
        expect(cubit.state.status, TtsStatus.idle);
        // The sentence list is still the one on screen, so play has to carry on
        // from where the voice stopped rather than from the top.
        expect(prefs.resumePoint('b1')?.sentenceIndex, 2);
        await cubit.close();
      });

      test('leaves a live session alone', () async {
        final cubit = await build();
        cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
        platform.becomeReady();
        await Future<void>.delayed(Duration.zero);
        await cubit.play();
        platform.emit(const TtsSentenceStarted(2));
        await Future<void>.delayed(Duration.zero);
        final stopsBefore = platform.stopCalls;

        await cubit.syncWithEngine();

        expect(cubit.state.isActive, isTrue);
        expect(platform.stopCalls, stopsBefore);
        await cubit.close();
      });

      test('does not ask the platform when nothing is playing', () async {
        final cubit = await build();
        cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
        platform.becomeReady();
        await Future<void>.delayed(Duration.zero);

        await cubit.syncWithEngine();

        // No channel round trip on a path that runs every time the reader opens.
        expect(cubit.state.status, TtsStatus.idle);
        await cubit.close();
      });
    });

    test('closing the reader leaves the service running', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();

      await cubit.close();
      // Narration is meant to outlive the reader screen; that is the whole point
      // of the service.
      expect(platform.stopServiceCalls, 0);
    });

    test('a notification-initiated stop re-arms the service', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();
      expect(platform.serviceUp, isTrue);

      // What the lockscreen Stop button does: it kills the engine and the
      // service natively, and Dart finds out only through the event.
      platform.emit(const TtsStopped());
      await Future<void>.delayed(Duration.zero);

      await cubit.play();
      // The second start call proves the flag was cleared, so the service is
      // really brought back up rather than assumed to be running — otherwise
      // narration would start with nothing keeping the process alive.
      expect(platform.startServiceCalls, 2);
      expect(platform.serviceUp, isTrue);
      await cubit.close();
    });

    test('turning background playback off stops the service', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();
      expect(platform.serviceUp, isTrue);

      await cubit.setBackgroundPlayback(false);
      expect(platform.serviceUp, isFalse);
      expect(cubit.state.backgroundPlayback, isFalse);
      expect(prefs.backgroundPlayback, isFalse);
      await cubit.close();
    });

    test('play does not start the service when it is turned off', () async {
      await prefs.setBackgroundPlayback(false);
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);

      await cubit.play();
      expect(platform.startServiceCalls, 0);
      await cubit.close();
    });
  });

  group('chapter auto-advance', () {
    /// Stands in for the reader: turns to the next chapter and hands it back,
    /// which is the order the real one does it in — the reader loads and lays
    /// out the chapter first, and only then does the coordinator learn what
    /// sentences it contains. Takes no index on purpose, matching the real
    /// contract: only the reader knows which chapter it is on.
    void installReader(
      TtsCubit cubit,
      _FakeChapterSource source,
      List<int> navigated, {
      bool Function(int index)? canOpen,
      Duration? turn,
    }) {
      var at = 0;
      cubit.attachChapterNavigator(() async {
        final next = at + 1;
        navigated.add(next);
        if (next >= source.count) return false;
        if (canOpen != null && !canOpen(next)) return false;
        // Standing in for a real chapter fetch, which takes long enough for a
        // second completion to arrive while this one is still in flight.
        if (turn != null) await Future<void>.delayed(turn);
        at = next;
        cubit.adoptChapter(
          bookId: 'b1',
          chapterId: source.chapterId(next),
          views: [
            for (final s
                in SentenceParser.parseHtml(
                  await source.chapterText(next),
                ).sentences)
              TtsSentenceView(
                index: s.index,
                text: s.text,
                blockIndex: s.blockIndex,
                pauseAfterMs: s.pauseAfterMs,
              ),
          ],
        );
        return true;
      });
    }

    Future<TtsCubit> withChapters({int count = 3}) async {
      final cubit = await build();
      final source = _FakeChapterSource(count: count);
      cubit.attachChapterSource(
        autoAdvance: TtsAutoAdvance(source: source, index: 0),
        workTitle: 'Test Book',
      );
      installReader(cubit, source, []);
      cubit.loadChapter(bookId: 'b1', chapterId: 'c0', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();
      return cubit;
    }

    test('finishing a chapter turns the page and carries on', () async {
      final cubit = await withChapters();
      expect(cubit.state.currentIndex, 0);

      platform.emit(const TtsCompleted());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(cubit.state.isSpeaking, isTrue);
      expect(cubit.state.chapterId, isNot('c0'));
      expect(cubit.state.currentIndex, 0);
      expect(cubit.state.totalSentences, greaterThan(0));
      // The service stays up across the chapter boundary: stopping it would
      // drop the notification mid-listen.
      expect(platform.serviceUp, isTrue);
      await cubit.close();
    });

    test('the reader is asked to turn the page, not told afterwards', () async {
      // The bug this guards: the coordinator used to load and narrate the next
      // chapter itself, so the voice read on while the screen stayed on the old
      // chapter. Nothing highlighted, the panel quoted a chapter nobody could
      // see, and it looked like the page had never moved.
      final cubit = await build();
      final source = _FakeChapterSource(count: 3);
      cubit.attachChapterSource(
        autoAdvance: TtsAutoAdvance(source: source, index: 0),
        workTitle: 'Test Book',
      );
      final navigated = <int>[];
      installReader(cubit, source, navigated);
      cubit.loadChapter(bookId: 'b1', chapterId: 'c0', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();

      platform.emit(const TtsCompleted());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // The next chapter, and the chapter the reader adopted is the one being
      // spoken — the screen and the voice cannot disagree about which it is.
      expect(navigated, [1]);
      expect(cubit.state.chapterId, 'chapter-url-1');
      expect(cubit.state.isSpeaking, isTrue);
      await cubit.close();
    });

    test('the next chapter is read from its first sentence', () async {
      // A roll is the start of a chapter nobody has read, not a continuation of
      // a position that belonged to the previous one.
      final cubit = await build();
      final source = _FakeChapterSource(count: 3);
      cubit.attachChapterSource(
        autoAdvance: TtsAutoAdvance(source: source, index: 0),
        workTitle: 'Test Book',
      );
      installReader(cubit, source, []);
      cubit.loadChapter(bookId: 'b1', chapterId: 'c0', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();
      platform.emit(const TtsSentenceStarted(2));
      await Future<void>.delayed(Duration.zero);

      platform.emit(const TtsCompleted());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(cubit.state.currentIndex, 0);
      expect(platform.lastStartIndex, 0);
      await cubit.close();
    });

    test('a chapter that will not turn the page ends the session', () async {
      // Rather than carry on speaking a chapter the reader could not open, which
      // would leave a notification running with nothing behind it.
      final cubit = await build();
      final source = _FakeChapterSource(count: 3);
      cubit.attachChapterSource(
        autoAdvance: TtsAutoAdvance(source: source, index: 0),
        workTitle: 'Test Book',
      );
      installReader(cubit, source, [], canOpen: (_) => false);
      cubit.loadChapter(bookId: 'b1', chapterId: 'c0', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();

      platform.emit(const TtsCompleted());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(cubit.state.status, TtsStatus.idle);
      expect(platform.serviceUp, isFalse);
      await cubit.close();
    });

    test('a repeated completion does not tear down the chapter it just started',
        () async {
      // The engine can report completion twice: once when the last sentence
      // finishes and again as a flushed queue drains. The second advance finds
      // a chapter that is no longer the one it asked for, calls the move a
      // failure, and stops the service the first one had just started — which
      // from the outside is indistinguishable from auto-advance never working.
      final cubit = await build();
      final source = _FakeChapterSource(count: 3);
      cubit.attachChapterSource(
        autoAdvance: TtsAutoAdvance(source: source, index: 0),
        workTitle: 'Test Book',
      );
      final navigated = <int>[];
      installReader(cubit, source, navigated, turn: const Duration(milliseconds: 20));
      cubit.loadChapter(bookId: 'b1', chapterId: 'c0', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();

      platform.emit(const TtsCompleted());
      platform.emit(const TtsCompleted());
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(navigated, [1], reason: 'the second completion must be ignored');
      expect(cubit.state.chapterId, 'chapter-url-1');
      expect(cubit.state.isSpeaking, isTrue);
      expect(platform.serviceUp, isTrue);
      await cubit.close();
    });

    test('completing with nothing that can turn the page stops the session',
        () async {
      // A chapter list but no screen attached: background narration with no
      // reader is the end of the session, not an infinite roll.
      final cubit = await build();
      cubit.attachChapterSource(
        autoAdvance: TtsAutoAdvance(source: _FakeChapterSource(count: 3), index: 0),
        workTitle: 'Test Book',
      );
      cubit.loadChapter(bookId: 'b1', chapterId: 'c0', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();

      platform.emit(const TtsCompleted());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(cubit.state.status, TtsStatus.idle);
      expect(platform.serviceUp, isFalse);
      await cubit.close();
    });

    test('advancing keeps the same book', () async {
      final cubit = await withChapters();
      platform.emit(const TtsCompleted());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // The resume point is keyed by book, so a chapter roll must not orphan it.
      expect(cubit.state.bookId, 'b1');
      await cubit.close();
    });

    test('the auto-advanced chapter id is one the app can reopen', () async {
      final cubit = await withChapters();
      platform.emit(const TtsCompleted());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // The id has to match what the reader passes when it opens that chapter
      // directly, or the saved point is unreachable and the resume offer can
      // never appear again for that chapter.
      final point = cubit.resumePointFor('b1', 'chapter-url-1');
      expect(point, isNull, reason: 'no position saved yet at sentence 0');

      // Advancing the chapter must not have built a chain id.
      expect(cubit.state.chapterId, isNot(contains('#')));
      await cubit.close();
    });

    test('the end of the book stops instead of looping', () async {
      final cubit = await build();
      final source = _FakeChapterSource(count: 1);
      cubit.attachChapterSource(
        autoAdvance: TtsAutoAdvance(source: source, index: 0),
        workTitle: 'Test Book',
      );
      installReader(cubit, source, []);
      cubit.loadChapter(bookId: 'b1', chapterId: 'c0', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();

      platform.emit(const TtsCompleted());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(cubit.state.status, TtsStatus.idle);
      expect(platform.serviceUp, isFalse);
      await cubit.close();
    });

    test('completing with no chapter source stops the session', () async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: _chapterHtml);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      await cubit.play();

      platform.emit(const TtsCompleted());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Reader closed: nothing to advance into, so this is the end.
      expect(cubit.state.status, TtsStatus.idle);
      expect(platform.serviceUp, isFalse);
      await cubit.close();
    });

    test('a detached source stops advancing', () async {
      final cubit = await withChapters();
      cubit.detachChapterSource();

      platform.emit(const TtsCompleted());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(cubit.state.status, TtsStatus.idle);
      await cubit.close();
    });

    test('a completion after stopping is ignored', () async {
      // The engine can emit one late: a queued retry firing 120ms after a stop,
      // or a flushed queue draining. Acting on it would turn the page and start
      // reading a chapter the user had just stopped, which is indistinguishable
      // from the app ignoring the stop button.
      final cubit = await withChapters();
      final navigated = <int>[];
      installReader(cubit, _FakeChapterSource(count: 3), navigated);
      await cubit.stop();

      platform.emit(const TtsCompleted());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(navigated, isEmpty);
      expect(cubit.state.status, TtsStatus.idle);
      expect(cubit.state.isSpeaking, isFalse);
      await cubit.close();
    });

    test('closing the reader stops a later completion advancing', () async {
      final cubit = await withChapters();
      await cubit.close();

      // The service is still narrating, but a completion must not try to fetch
      // a chapter the user is no longer in.
      platform.emit(const TtsCompleted());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(platform.serviceUp, isTrue);
    });
  });

  group('resume re-anchoring', () {
    const html = '<p>Alpha one. Beta two. Gamma three. Delta four.</p>';

    Future<TtsCubit> loaded() async {
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: html);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);
      return cubit;
    }

    test('a fingerprint is written alongside the index', () async {
      final cubit = await loaded();
      await cubit.play();
      platform.emit(const TtsSentenceStarted(2));
      await Future<void>.delayed(Duration.zero);
      await cubit.pause();

      final point = prefs.resumePoint('b1');
      expect(point?.sentenceIndex, 2);
      expect(point?.fingerprint, isNotNull);
      expect(point?.fingerprint, hasLength(8));
      await cubit.close();
    });

    test('an index that still means the same sentence is used as-is', () async {
      final cubit = await loaded();
      final point = TtsResumePoint(
        chapterId: 'c1',
        sentenceIndex: 2,
        fingerprint: TtsResumePoint.fingerprintOf('Gamma three.'),
      );
      expect(cubit.resolveResumeIndex(point), 2);
      await cubit.close();
    });

    test('a stale index is moved to the sentence the point meant', () async {
      final cubit = await loaded();
      // The point was saved when the chapter had two more sentences before
      // this one, so 2 now names a different sentence.
      final point = TtsResumePoint(
        chapterId: 'c1',
        sentenceIndex: 1,
        fingerprint: TtsResumePoint.fingerprintOf('Gamma three.'),
      );
      expect(cubit.resolveResumeIndex(point), 2);
      await cubit.close();
    });

    test('an old point with no fingerprint falls back to its index', () async {
      final cubit = await loaded();
      // Nothing to check against, so the index is taken at face value rather
      // than guessed at.
      expect(cubit.resolveResumeIndex(
        const TtsResumePoint(chapterId: 'c1', sentenceIndex: 3),
      ), 3);
      await cubit.close();
    });

    test('a fingerprint that matches nothing still resumes', () async {
      final cubit = await loaded();
      // The sentence was filtered out or the chapter was edited. Refusing to
      // resume would be worse than resuming a little off.
      expect(
        cubit.resolveResumeIndex(
          const TtsResumePoint(
            chapterId: 'c1',
            sentenceIndex: 99,
            fingerprint: 'deadbeef',
          ),
        ),
        3,
      );
      await cubit.close();
    });

    test('the nearest match wins when a sentence repeats', () async {
      const repeated = '<p>He waited. She left. He waited. She left.</p>';
      final cubit = await build();
      cubit.loadChapter(bookId: 'b1', chapterId: 'c1', html: repeated);
      platform.becomeReady();
      await Future<void>.delayed(Duration.zero);

      // "He waited." occurs twice; the point means the later one, so the lookup
      // must not jump back to the first.
      expect(
        cubit.resolveResumeIndex(
          TtsResumePoint(
            chapterId: 'c1',
            sentenceIndex: 3,
            fingerprint: TtsResumePoint.fingerprintOf('He waited.'),
          ),
        ),
        2,
      );
      await cubit.close();
    });

    test('the fingerprint is stable across identical text', () {
      // Dart gives no stability guarantee for String.hashCode, so this is the
      // reason the hash is hand-rolled.
      expect(
        TtsResumePoint.fingerprintOf('He drew his blade.'),
        TtsResumePoint.fingerprintOf('He drew his blade.'),
      );
      expect(
        TtsResumePoint.fingerprintOf('He drew his blade.'),
        isNot(TtsResumePoint.fingerprintOf('He drew his sword.')),
      );
    });
  });
}

/// Chapter list for the auto-advance tests.
class _FakeChapterSource implements TtsChapterSource {
  _FakeChapterSource({this.count = 3});

  final int count;

  @override
  Future<int> chapterCount() async => count;

  @override
  Future<String> chapterTitle(int index) async => 'Chapter ${index + 1}';

  @override
  Future<String> chapterText(int index) async =>
      '<p>Chapter $index opens. It continues.</p>';

  @override
  String chapterId(int index) => 'chapter-url-$index';
}

