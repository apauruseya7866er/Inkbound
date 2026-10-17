import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/features/reader/tts_highlight_box.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('reader_prefs_defaults');
    Hive.init(dir.path);
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  group("new pref defaults (fresh box == today's behavior)", () {
    test('manga defaults', () async {
      await ReaderPrefs.init();
      final p = ReaderPrefs();
      expect(p.readingMode, 'ltr'); // matches the default legacy direction
      expect(p.fitMode, 'contain');
      expect(p.mangaBackground, 'black'); // matches the default legacy value
      expect(p.doublePageLandscape, isFalse);
      expect(p.cropBorders, isFalse);
      expect(p.webtoonPageGap, 0);
      expect(p.colorFilter, 'none');
    });

    test('shared comfort defaults', () async {
      await ReaderPrefs.init();
      final p = ReaderPrefs();
      expect(p.brightness, -1); // system/off — reader has never touched this
      expect(p.orientation, 'system'); // no lock — today's behavior
      expect(p.keepScreenOn, isTrue); // pre-existing, unaffected
    });

    test('novel defaults', () async {
      await ReaderPrefs.init();
      final p = ReaderPrefs();
      expect(p.fontFamily, 'inter');
      expect(p.textAlignJustify, isFalse);
      expect(p.paragraphSpacing, 8);
      expect(p.novelPaginated, isFalse);
      expect(p.highlightColor, 'blue');
      expect(p.highlightTextColor, 'default');
    });

    test('the highlight default resolves to a real palette colour', () async {
      // The default is spelled out as a literal in ReaderPrefs because core
      // does not import from features anywhere in this app, so the palette's own
      // default cannot be the source of truth here. This is the test that stops
      // the two copies drifting apart: rename a palette entry and this fails
      // instead of leaving every untouched install on a colour that no longer
      // exists.
      await ReaderPrefs.init();
      final stored = ReaderPrefs().highlightColor;
      final choice = ttsHighlightChoiceFor(stored);
      expect(choice.id, stored);
      expect(choice.id, kDefaultTtsHighlightId);
      expect(choice.color, isNot(const Color(0x00000000)));
    });

    test('the highlight-text default resolves to a real palette entry', () async {
      // Same guard for the second setting: the default means "leave the words
      // alone", which only works if that id still means that.
      await ReaderPrefs.init();
      final stored = ReaderPrefs().highlightTextColor;
      final choice = ttsHighlightTextChoiceFor(stored);
      expect(choice.id, stored);
      expect(choice.id, kDefaultTtsHighlightTextId);
      expect(choice.color, isNull, reason: 'the default must recolour nothing');
    });
  });

  group('migrate-on-read from legacy keys', () {
    test('readingMode derives from direction until explicitly set', () async {
      await ReaderPrefs.init();
      final p = ReaderPrefs();

      await p.setDirection('ltr');
      expect(p.readingMode, 'ltr');
      await p.setDirection('rtl');
      expect(p.readingMode, 'rtl');
      await p.setDirection('vertical');
      expect(p.readingMode, 'webtoon');

      // Once readingMode is explicitly written, it wins over direction.
      await p.setReadingMode('webtoon');
      await p.setDirection('ltr');
      expect(p.readingMode, 'webtoon');
    });

    test(
      'mangaBackground derives from background until explicitly set',
      () async {
        await ReaderPrefs.init();
        final p = ReaderPrefs();

        await p.setBackground('black');
        expect(p.mangaBackground, 'black');
        await p.setBackground('dark');
        expect(p.mangaBackground, 'system');

        // Once mangaBackground is explicitly written, it wins over background.
        await p.setMangaBackground('gray');
        await p.setBackground('black');
        expect(p.mangaBackground, 'gray');
      },
    );

    test('legacy direction/background getters keep working untouched', () async {
      await ReaderPrefs.init();
      final p = ReaderPrefs();
      await p.setDirection('rtl');
      await p.setBackground('dark');
      expect(p.direction, 'rtl');
      expect(p.background, 'dark');
    });
  });
}
