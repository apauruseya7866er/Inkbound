import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:watch_app/core/reading/tts/method_channel_tts_platform.dart';
import 'package:watch_app/core/reading/tts/tts_platform.dart';

/// End-to-end checks of the native TTS bridge on a real device.
///
/// These are the only tests that can catch what the Dart unit tests structurally
/// cannot: a channel that was never registered, a manifest missing the
/// TTS_SERVICE query (which makes `voices()` come back empty on Android 11+), an
/// engine that initialises but never speaks, or a stale callback from a previous
/// run moving the highlight backwards.
///
/// ### Running them
///
/// Needs x86_64 native libs, which this project strips from every build as
/// emulator-only bloat (see the `includeEmulatorAbis` gate in
/// `android/app/build.gradle.kts`). Add this to `android/gradle.properties` to
/// run on an emulator:
///
/// ```properties
/// includeEmulatorAbis=true
/// ```
///
/// ```sh
/// flutter test integration_test/tts_bridge_test.dart -d <device>
/// ```
///
/// ### The capability probe
///
/// The audio tests are skipped, not failed, on a device that cannot actually
/// speak. A bare emulator image has no voice data at all (`/product/voice-packs`
/// and `/system/tts` do not exist), so `speak()` accepts the utterance, the
/// engine never synthesises, and no progress callback ever arrives. Every audio
/// test would then fail for a reason that has nothing to do with this code — and
/// a suite that is always red is one you learn to ignore. The probe below
/// speaks one word first and skips with an explicit reason when nothing
/// responds, so on real hardware and on an emulator with voice data installed
/// the assertions all run in full.
Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final canSpeak = await _probeSpeechCapability();
  // `testWidgets`'s `skip` only takes a bool, not a reason, so the explanation
  // is printed once here where it cannot be missed.
  // ignore: avoid_print
  print(
    canSpeak
        ? '[tts] device can speak; running the full audio suite'
        : '[tts] SKIPPING the audio suite: this device reported a ready engine '
              'but never responded to an utterance, which means it has no TTS '
              'voice data installed. Everything that does not require audible '
              'synthesis still runs.',
  );


  group('bridge registration', () {
    // Always run: these prove the channel exists at all, which is worth knowing
    // even on a device that cannot speak.
    testWidgets('the engine initialises on a real device', (tester) async {
      final platform = MethodChannelTtsPlatform();
      addTearDown(platform.dispose);
      final events = <TtsEngineEvent>[];
      platform.events.listen(events.add);

      await platform.init();
      // Readiness arrives on the event channel, not as init()'s return value, so
      // a successful return proves nothing on its own.
      final ready = await _poll<TtsInitialised>(
        () => _firstOf(events.whereType<TtsInitialised>()),
        const Duration(seconds: 25),
      );
      expect(ready, isNotNull, reason: 'no init event arrived from the engine');
      expect(ready!.ready, isTrue, reason: 'engine reported itself unusable');
    });

    testWidgets('the device enumerates voices', (tester) async {
      final platform = MethodChannelTtsPlatform();
      addTearDown(platform.dispose);
      await platform.init();
      await Future<void>.delayed(const Duration(seconds: 3));

      final voices = await platform.voices();
      // Empty here means the manifest is missing the TTS_SERVICE query, so
      // package visibility hid every engine on Android 11+.
      expect(voices, isNotEmpty, reason: 'getVoices() returned nothing');
      for (final v in voices) {
        expect(v.name, isNotEmpty);
        expect(v.locale, isNotEmpty);
      }
    });

    testWidgets('language availability is reported without throwing', (
      tester,
    ) async {
      final platform = MethodChannelTtsPlatform();
      addTearDown(platform.dispose);
      await platform.init();
      await Future<void>.delayed(const Duration(seconds: 3));

      // A nonsense tag must come back unusable rather than throwing.
      final bogus = await platform.languageStatus('zz-ZZ');
      expect(bogus.canSpeak, isFalse);
    });

    testWidgets('voice, rate and pitch are accepted by the engine', (
      tester,
    ) async {
      final platform = MethodChannelTtsPlatform();
      addTearDown(platform.dispose);
      await platform.init();
      await Future<void>.delayed(const Duration(seconds: 3));

      final voices = await platform.voices();
      expect(voices, isNotEmpty);

      // A real voice name must not throw whatever the engine makes of it: a
      // rejected voice falls back to the default rather than breaking playback.
      await platform.setVoice(voices.first.name);
      await platform.setRate(1.3);
      await platform.setPitch(0.9);
      await platform.setVoice(null);
    });

    testWidgets('out-of-range rates are clamped, not fatal', (tester) async {
      final platform = MethodChannelTtsPlatform();
      addTearDown(platform.dispose);
      await platform.init();
      await Future<void>.delayed(const Duration(seconds: 3));
      await platform.setRate(99);
      await platform.setRate(-5);
      await platform.setRate(1.0);
    });

    testWidgets('an empty sentence list is rejected', (tester) async {
      final platform = MethodChannelTtsPlatform();
      addTearDown(platform.dispose);
      await platform.init();
      await Future<void>.delayed(const Duration(seconds: 3));

      // The bridge answers with a platform error, which the platform layer
      // rethrows for `start` because a failure there means no audio at all.
      await expectLater(
        platform.start(units: const [], startIndex: 0),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('speech', () {
    // No shared setUp: each test builds its own platform and its own event log,
    // because a shared subscription would let one test's leftover events satisfy
    // the next test's wait.
    testWidgets('speaking reports progress and then completes', (
      tester,
    ) async {
      final platform = MethodChannelTtsPlatform();
      final events = <TtsEngineEvent>[];
      platform.events.listen(events.add);
      addTearDown(platform.dispose);
      await _ready(platform, events);

      await platform.start(
        units: const [
          TtsUnit(text: 'Testing one.', pauseAfterMs: 100),
          TtsUnit(text: 'Testing two.', pauseAfterMs: 100),
          TtsUnit(text: 'Testing three.', pauseAfterMs: 0),
        ],
        startIndex: 0,
      );

      final started = await _poll<TtsSentenceStarted>(
        () => _firstOf(events.whereType<TtsSentenceStarted>()),
        const Duration(seconds: 30),
      );
      expect(started, isNotNull, reason: 'no sentence ever started');
      expect(started!.index, 0);

      expect(
        await _poll<TtsCompleted>(
          () => _firstOf(events.whereType<TtsCompleted>()),
          const Duration(seconds: 30),
        ),
        isNotNull,
        reason: 'playback never completed; saw '
            '${events.map((e) => e.runtimeType).toList()}',
      );
    }, skip: !canSpeak);

    testWidgets('every sentence in a run is announced in order', (
      tester,
    ) async {
      final platform = MethodChannelTtsPlatform();
      final events = <TtsEngineEvent>[];
      platform.events.listen(events.add);
      addTearDown(platform.dispose);
      await _ready(platform, events);

      const count = 5;
      await platform.start(
        units: List.generate(
          count,
          (i) => TtsUnit(text: 'Sentence $i.', pauseAfterMs: 60),
        ),
        startIndex: 0,
      );

      expect(
        await _poll<TtsCompleted>(
          () => _firstOf(events.whereType<TtsCompleted>()),
          const Duration(seconds: 60),
        ),
        isNotNull,
        reason: 'run never completed',
      );

      final order = events
          .whereType<TtsSentenceStarted>()
          .map((e) => e.index)
          .toList();
      expect(
        order,
        List.generate(count, (i) => i),
        reason: 'sentences were announced out of order or skipped: $order',
      );
    }, skip: !canSpeak);

    testWidgets('resuming mid-chapter starts at the requested sentence', (
      tester,
    ) async {
      final platform = MethodChannelTtsPlatform();
      final events = <TtsEngineEvent>[];
      platform.events.listen(events.add);
      addTearDown(platform.dispose);
      await _ready(platform, events);

      await platform.start(
        units: List.generate(
          12,
          (i) => TtsUnit(text: 'Sentence $i.', pauseAfterMs: 40),
        ),
        startIndex: 5,
      );

      final started = await _poll<TtsSentenceStarted>(
        () => _firstOf(events.whereType<TtsSentenceStarted>()),
        const Duration(seconds: 30),
      );
      expect(started, isNotNull, reason: 'nothing started speaking');
      // Starting at 5 must not replay the five sentences before it.
      expect(started!.index, 5);
    }, skip: !canSpeak);

    testWidgets('pause and resume are honoured', (tester) async {
      final platform = MethodChannelTtsPlatform();
      final events = <TtsEngineEvent>[];
      platform.events.listen(events.add);
      addTearDown(platform.dispose);
      await _ready(platform, events);

      // Long enough that pausing mid-run is meaningful.
      await platform.start(
        units: List.generate(
          40,
          (i) => TtsUnit(text: 'Sentence number $i.', pauseAfterMs: 50),
        ),
        startIndex: 0,
      );
      expect(
        await _poll<TtsSentenceStarted>(
          () => _firstOf(events.whereType<TtsSentenceStarted>()),
          const Duration(seconds: 30),
        ),
        isNotNull,
        reason: 'nothing started speaking',
      );

      await platform.pause();
      expect(
        await _poll<TtsPaused>(
          () => _firstOf(events.whereType<TtsPaused>()),
          const Duration(seconds: 15),
        ),
        isNotNull,
        reason: 'pause was never acknowledged',
      );

      final before = events.whereType<TtsSentenceStarted>().length;
      await platform.resume();
      // Resuming must produce fresh progress, not just return quietly.
      final after = await _poll<int>(
        () async => events.whereType<TtsSentenceStarted>().length,
        const Duration(seconds: 25),
      );
      expect(after, isNotNull, reason: 'resume produced no further speech');
      expect(after, greaterThan(before));
    }, skip: !canSpeak);

    testWidgets('stop halts playback', (tester) async {
      final platform = MethodChannelTtsPlatform();
      final events = <TtsEngineEvent>[];
      platform.events.listen(events.add);
      addTearDown(platform.dispose);
      await _ready(platform, events);

      await platform.start(
        units: List.generate(
          40,
          (i) => TtsUnit(text: 'Sentence number $i.', pauseAfterMs: 50),
        ),
        startIndex: 0,
      );
      expect(
        await _poll<TtsSentenceStarted>(
          () => _firstOf(events.whereType<TtsSentenceStarted>()),
          const Duration(seconds: 30),
        ),
        isNotNull,
        reason: 'nothing started speaking',
      );

      await platform.stop();
      expect(
        await _poll<TtsStopped>(
          () => _firstOf(events.whereType<TtsStopped>()),
          const Duration(seconds: 15),
        ),
        isNotNull,
        reason: 'stop was never acknowledged',
      );
    }, skip: !canSpeak);

    testWidgets('a stop mid-run does not leave the old run speaking', (
      tester,
    ) async {
      final platform = MethodChannelTtsPlatform();
      final events = <TtsEngineEvent>[];
      platform.events.listen(events.add);
      addTearDown(platform.dispose);
      await _ready(platform, events);

      // Start a long run, stop it, then start a different one. The second run
      // must report only itself: a stale callback from the first would drag the
      // highlight back to sentence 0.
      await platform.start(
        units: List.generate(
          40,
          (i) => TtsUnit(text: 'First run sentence $i.', pauseAfterMs: 50),
        ),
        startIndex: 0,
      );
      await _poll<TtsSentenceStarted>(
        () => _firstOf(events.whereType<TtsSentenceStarted>()),
        const Duration(seconds: 30),
      );
      await platform.stop();
      events.clear();

      await platform.start(
        units: List.generate(
          40,
          (i) => TtsUnit(text: 'Second run sentence $i.', pauseAfterMs: 50),
        ),
        startIndex: 7,
      );

      final started = await _poll<TtsSentenceStarted>(
        () => _firstOf(events.whereType<TtsSentenceStarted>()),
        const Duration(seconds: 30),
      );
      expect(started, isNotNull);
      expect(
        started!.index,
        7,
        reason: 'a stale callback from the first run won',
      );
    }, skip: !canSpeak);
  });
  group('foreground service', () {
    testWidgets('the service starts, reports running, and stops', (
      tester,
    ) async {
      final platform = MethodChannelTtsPlatform();
      addTearDown(platform.dispose);
      await platform.init();
      await Future<void>.delayed(const Duration(seconds: 3));

      expect(await platform.serviceRunning(), isFalse);

      // On Android 14+ a mediaPlayback foreground service with the matching
      // permission is required; a missing type or permission throws here rather
      // than silently degrading.
      await platform.startService(title: 'A Wizard of Earthsea', sentence: '');

      // startForegroundService is asynchronous, so give the system a moment to
      // promote it before asserting.
      var running = false;
      for (var i = 0; i < 25; i++) {
        running = await platform.serviceRunning();
        if (running) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(running, isTrue, reason: 'foreground service never started');

      await platform.updateService(
        title: 'A Wizard of Earthsea',
        sentence: 'The first sentence.',
      );

      await platform.stopService();
      var stopped = true;
      for (var i = 0; i < 25; i++) {
        stopped = !(await platform.serviceRunning());
        if (stopped) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(stopped, isTrue, reason: 'foreground service never stopped');
    });

    testWidgets('updating the service when it is not running is harmless', (
      tester,
    ) async {
      final platform = MethodChannelTtsPlatform();
      addTearDown(platform.dispose);
      await platform.init();
      await Future<void>.delayed(const Duration(seconds: 3));

      // The reader can emit a sentence event after the service was already
      // torn down; that must not resurrect it or throw.
      await platform.updateService(title: 'x', sentence: 'y');
      expect(await platform.serviceRunning(), isFalse);
    });

    testWidgets('stopping the service when it never ran is harmless', (
      tester,
    ) async {
      final platform = MethodChannelTtsPlatform();
      addTearDown(platform.dispose);
      await platform.init();
      await Future<void>.delayed(const Duration(seconds: 3));

      await platform.stopService();
      expect(await platform.serviceRunning(), isFalse);
    });
  });
}

/// Whether this device can actually turn an utterance into sound.
///
/// Speaks one word and waits for any response. `ready` is not enough: an engine
/// with no voice data installed still reports itself ready, accepts the
/// utterance, and then never calls back.
Future<bool> _probeSpeechCapability() async {
  final platform = MethodChannelTtsPlatform();
  try {
    final events = <TtsEngineEvent>[];
    platform.events.listen(events.add);
    await platform.init();

    final ready = await _poll<TtsInitialised>(
      () => _firstOf(events.whereType<TtsInitialised>()),
      const Duration(seconds: 25),
    );
    if (ready == null || !ready.ready) return false;

    await platform.start(
      units: const [TtsUnit(text: 'Testing.', pauseAfterMs: 0)],
      startIndex: 0,
    );

    // Only speech events count. Matching "any event" here would be satisfied by
    // the TtsInitialised event already sitting in the list, so the probe would
    // report success on a device that cannot speak at all — the exact
    // false-confidence this exists to prevent.
    final spoke = await _poll<TtsEngineEvent>(
      () => _firstOf(
        events.where(
          (e) =>
              e is TtsSentenceStarted ||
              e is TtsUtteranceFailed ||
              e is TtsCompleted,
        ),
      ),
      const Duration(seconds: 20),
    );
    return spoke != null;
  } catch (_) {
    // No bridge, no engine: nothing downstream can work either.
    return false;
  } finally {
    await platform.stop();
    await platform.dispose();
  }
}

/// Waits for the engine's init event and fails loudly if it never comes.
Future<void> _ready(
  MethodChannelTtsPlatform platform,
  List<TtsEngineEvent> events,
) async {
  await platform.init();
  final ready = await _poll<TtsInitialised>(
    () => _firstOf(events.whereType<TtsInitialised>()),
    const Duration(seconds: 25),
  );
  expect(ready, isNotNull, reason: 'no init event arrived from the engine');
  expect(ready!.ready, isTrue, reason: 'engine reported itself unusable');
}

/// Polls [probe] until it returns non-null or [timeout] elapses.
///
/// Polling rather than awaiting a future because engine events arrive
/// asynchronously from a native listener; there is no future to await.
/// [probe] may be sync or async so a captured list can be read directly.
Future<T?> _poll<T>(
  FutureOr<T?> Function() probe,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = await probe();
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return null;
}

/// First element, or null when empty.
///
/// A top-level function rather than an extension getter: Dart 3 ships its own
/// `firstOrNull` on `Iterable`, and a same-named extension made inference
/// ambiguous at every call site.
T? _firstOf<T>(Iterable<T> items) => items.isEmpty ? null : items.first;




