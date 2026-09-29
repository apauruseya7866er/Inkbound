import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/reading/tts/tts_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late TtsPrefs prefs;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tts_prefs_test_');
    Hive.init(tempDir.path);
    await TtsPrefs.init();
    prefs = TtsPrefs();
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('speech settings', () {
    test('defaults are neutral', () {
      expect(prefs.voiceName, isNull);
      expect(prefs.rate, 1.0);
      expect(prefs.pitch, 1.0);
      expect(prefs.sleepTimerMinutes, 0);
    });

    test('settings round-trip', () async {
      await prefs.setVoiceName('en-GB-voice');
      await prefs.setRate(1.5);
      await prefs.setPitch(0.75);
      expect(prefs.voiceName, 'en-GB-voice');
      expect(prefs.rate, 1.5);
      expect(prefs.pitch, 0.75);
    });

    test('an empty voice name reads as no override', () async {
      await prefs.setVoiceName('');
      // An empty string would otherwise be pushed to the engine as a voice name
      // that matches nothing, leaving the user on a silent fallback.
      expect(prefs.voiceName, isNull);
    });

    test('rate is clamped to the usable range', () async {
      await prefs.setRate(10);
      // Was 2.0 until the speed button needed 3x. Asserted against the
      // constant rather than a literal so the ceiling is stated once.
      expect(prefs.rate, TtsSpeed.max);
      await prefs.setRate(0.01);
      expect(prefs.rate, 0.5);
    });

    test('pitch is clamped to the usable range', () async {
      await prefs.setPitch(99);
      expect(prefs.pitch, 2.0);
      await prefs.setPitch(-3);
      expect(prefs.pitch, 0.5);
    });

    test('a non-finite rate falls back to neutral', () async {
      await prefs.setRate(double.nan);
      expect(prefs.rate, 1.0);
      await prefs.setRate(double.infinity);
      expect(prefs.rate, 1.0);
    });

    test('a negative sleep timer reads as off', () async {
      await prefs.setSleepTimerMinutes(-5);
      expect(prefs.sleepTimerMinutes, 0);
    });
  });

  group('resume points', () {
    test('no point is stored initially', () {
      expect(prefs.resumePoint('b1'), isNull);
    });

    test('a point round-trips', () async {
      await prefs.setResumePoint('b1', 'c1', 12);
      final point = prefs.resumePoint('b1');
      expect(point?.chapterId, 'c1');
      expect(point?.sentenceIndex, 12);
    });

    test('sentence zero is not offered as resumable', () async {
      await prefs.setResumePoint('b1', 'c1', 0);
      // A book stopped at the very start of a chapter has nothing to resume;
      // offering it makes the feature look broken.
      expect(prefs.resumePoint('b1'), isNull);
    });

    test('points are kept per book', () async {
      await prefs.setResumePoint('b1', 'c1', 5);
      await prefs.setResumePoint('b2', 'c9', 40);
      expect(prefs.resumePoint('b1')?.sentenceIndex, 5);
      expect(prefs.resumePoint('b2')?.sentenceIndex, 40);
    });

    test('a later write replaces the earlier one', () async {
      await prefs.setResumePoint('b1', 'c1', 5);
      await prefs.setResumePoint('b1', 'c7', 9);
      expect(prefs.resumePoint('b1')?.chapterId, 'c7');
      expect(prefs.resumePoint('b1')?.sentenceIndex, 9);
    });

    test('clearing removes the point', () async {
      await prefs.setResumePoint('b1', 'c1', 5);
      await prefs.clearResumePoint('b1');
      expect(prefs.resumePoint('b1'), isNull);
    });

    test('the fingerprint round-trips with the point', () async {
      await prefs.setResumePoint('b1', 'c1', 12,
          fingerprint: TtsResumePoint.fingerprintOf('He drew his blade.'));
      expect(
        prefs.resumePoint('b1')?.fingerprint,
        TtsResumePoint.fingerprintOf('He drew his blade.'),
      );
    });

    test('a point written without one still reads back', () async {
      // Old data has no fingerprint and must not become unreadable.
      await prefs.setResumePoint('b1', 'c1', 12);
      expect(prefs.resumePoint('b1')?.fingerprint, isNull);
      expect(prefs.resumePoint('b1')?.sentenceIndex, 12);
    });

    test('clearing takes the fingerprint with it', () async {
      // Left behind, a stale fingerprint would be read as belonging to the next
      // point written for this book.
      await prefs.setResumePoint('b1', 'c1', 5, fingerprint: 'abc123');
      await prefs.clearResumePoint('b1');
      await prefs.setResumePoint('b1', 'c1', 5);
      expect(prefs.resumePoint('b1')?.fingerprint, isNull);
    });

    test('clearing one book leaves the others alone', () async {
      await prefs.setResumePoint('b1', 'c1', 5);
      await prefs.setResumePoint('b2', 'c2', 6);
      await prefs.clearResumePoint('b1');
      expect(prefs.resumePoint('b1'), isNull);
      expect(prefs.resumePoint('b2'), isNotNull);
    });

    test('an empty book id is ignored rather than creating a junk key',
        () async {
      await prefs.setResumePoint('', 'c1', 5);
      await prefs.clearResumePoint('');
      expect(prefs.resumePoint(''), isNull);
    });

    test('a chapter with no index reads as no point', () async {
      // Simulates a half-written pair, e.g. an interrupted first write.
      await Hive.box(TtsPrefs.boxName).put('resume.chapter.b1', 'c1');
      expect(prefs.resumePoint('b1'), isNull);
    });
  });

  group('speed presets', () {
    test('the list is the one that was asked for, slowest first', () {
      expect(TtsSpeed.presets, [
        1.0, 1.2, 1.3, 1.5, 1.7, 1.8, 2.0, 2.1, 2.3, 2.5, 3.0,
      ]);
    });

    test('the list only grows', () {
      for (var i = 1; i < TtsSpeed.presets.length; i++) {
        expect(
          TtsSpeed.presets[i],
          greaterThan(TtsSpeed.presets[i - 1]),
          reason: 'presets must ascend or cycling cannot terminate',
        );
      }
    });

    test('every preset is inside the range the engine accepts', () {
      // The clamp lives in three places — here, the settings slider and the
      // Kotlin engine. A preset outside it would show a speed that is silently
      // not the speed being spoken.
      for (final value in TtsSpeed.presets) {
        expect(value, inInclusiveRange(TtsSpeed.min, TtsSpeed.max));
      }
    });

    test('tapping walks up the list and wraps at the top', () {
      expect(TtsSpeed.next(1.0), 1.2);
      expect(TtsSpeed.next(1.2), 1.3);
      expect(TtsSpeed.next(2.3), 2.5);
      expect(TtsSpeed.next(2.5), 3.0);
      // Past the last preset there is nowhere to go but back to the start.
      expect(TtsSpeed.next(3.0), 1.0);
    });

    test('tapping a full cycle returns to where it started', () {
      var rate = 1.0;
      for (var i = 0; i < TtsSpeed.presets.length; i++) {
        rate = TtsSpeed.next(rate);
      }
      expect(rate, 1.0);
    });

    test('a rate between presets steps up rather than snapping down', () {
      // Set with the slider. "Faster" has to mean faster, or the button feels
      // broken at exactly the rates a person is likely to have chosen.
      expect(TtsSpeed.next(1.25), 1.3);
      expect(TtsSpeed.next(1.44), 1.5);
      expect(TtsSpeed.next(2.95), 3.0);
    });

    test('a rate below the slowest preset steps up to it', () {
      expect(TtsSpeed.next(0.5), 1.0);
      expect(TtsSpeed.next(0.9), 1.0);
    });

    test('cycling from a stored preset does not return the same value', () {
      // 1.2 is not storable as exactly 1.2, so a naive "greater than" would
      // hand back 1.2 and the button would appear to do nothing.
      for (final value in TtsSpeed.presets) {
        expect(
          TtsSpeed.next(value),
          isNot(equals(value)),
          reason: 'tapping $value must change the speed',
        );
      }
    });

    test('a nonsense rate does not throw', () {
      expect(TtsSpeed.next(double.nan), 1.0);
      expect(TtsSpeed.label(double.nan), '1x');
      expect(TtsSpeed.label(double.infinity), '1x');
    });

    test('labels drop the trailing zero so the chip stays narrow', () {
      expect(TtsSpeed.label(1.0), '1x');
      expect(TtsSpeed.label(1.2), '1.2x');
      expect(TtsSpeed.label(1.3), '1.3x');
      expect(TtsSpeed.label(2.0), '2x');
      expect(TtsSpeed.label(3.0), '3x');
      // A slider position that is not a tenth, e.g. 1.2499.
      expect(TtsSpeed.label(1.2499), '1.2x');
    });

    test('every preset has a label that reads back as itself', () {
      for (final value in TtsSpeed.presets) {
        final text = TtsSpeed.label(value);
        expect(text, endsWith('x'));
        expect(double.parse(text.substring(0, text.length - 1)),
            closeTo(value, 0.051));
      }
    });
  });

  group('rate range', () {
    test('a fast rate is kept, not clamped back to the old 2.0 ceiling', () async {
      await prefs.setRate(3.0);
      expect(prefs.rate, 3.0);
      await prefs.setRate(2.5);
      expect(prefs.rate, 2.5);
    });

    test('rates beyond the ceiling are pulled back to it', () async {
      await prefs.setRate(9.0);
      expect(prefs.rate, TtsSpeed.max);
      await prefs.setRate(0.1);
      expect(prefs.rate, TtsSpeed.min);
    });

    test('pitch keeps its own narrower range', () async {
      // Rate was widened to 3.0; pitch must not have come along with it, or
      // the chipmunk setting reappears.
      await prefs.setPitch(3.0);
      expect(prefs.pitch, 2.0);
    });
  });
}
