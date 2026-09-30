import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/core/reading/text_filter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ReaderPrefs prefs;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('reader_text_filter_test_');
    Hive.init(tempDir.path);
    await ReaderPrefs.init();
    prefs = ReaderPrefs();
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('cleanup is on by default, with every built-in rule active', () {
    expect(prefs.textFiltersEnabled, isTrue);
    expect(prefs.textFilterRules, isEmpty);
    expect(prefs.disabledTextFilterIds, isEmpty);
    expect(prefs.textFilterEngine.isEmpty, isFalse);
    expect(
      prefs.textFilterEngine.isFiltered('Please support me on Patreon'),
      isTrue,
    );
  });

  test('turning the master switch off makes the engine do nothing', () async {
    await prefs.setTextFiltersEnabled(false);
    expect(prefs.textFilterEngine.isEmpty, isTrue);
  });

  test('a disabled built-in is off, and the rest stay on', () async {
    await prefs.setDisabledTextFilterIds({'builtin_patreon'});
    final engine = prefs.textFilterEngine;
    // A line only that rule covers: "Please support me" is also a donation
    // plea, and the two rules overlap on purpose.
    expect(engine.isFiltered('Visit patreon.com/someone today'), isFalse);
    expect(engine.isFiltered('Join our discord for more'), isTrue);
    // The rule is still listed, just not firing — so it can be switched back on
    // without the user having to know its pattern.
    expect(
      prefs.activeTextFilterRules.length,
      builtinTextFilterRules.length,
    );
  });

  test('restoring the built-ins brings back a disabled one', () async {
    await prefs.setDisabledTextFilterIds({'builtin_patreon'});
    await prefs.setDisabledTextFilterIds(const {});
    expect(
      prefs.textFilterEngine.isFiltered('Visit patreon.com/someone today'),
      isTrue,
    );
  });

  group('hideTextEverywhere', () {
    test('adds an anchored rule that matches the sentence', () async {
      final rule = await prefs.hideTextEverywhere('VOTE FOR ME ON GOODNOVELS');
      expect(prefs.textFilterRules.map((r) => r.id), [rule.id]);
      expect(
        prefs.textFilterEngine.stripFiltered(
          'The battle began.\nVOTE FOR ME ON GOODNOVELS\nThe rain fell.',
        ),
        'The battle began.\nThe rain fell.',
      );
    });

    test('hiding the same sentence twice does not duplicate the rule', () async {
      final first = await prefs.hideTextEverywhere('The End');
      final second = await prefs.hideTextEverywhere('The End');
      expect(second.id, first.id);
      expect(prefs.textFilterRules, hasLength(1));
    });

    test('trims before matching, so trailing whitespace is not stored', () async {
      final rule = await prefs.hideTextEverywhere('  The End  ');
      expect(rule.pattern, r'^\s*The End\s*$');
    });

    test('removeTextFilterRule brings the sentence back', () async {
      final rule = await prefs.hideTextEverywhere('The End');
      expect(prefs.textFilterEngine.isFiltered('The End'), isTrue);
      await prefs.removeTextFilterRule(rule.id);
      expect(prefs.textFilterRules, isEmpty);
      expect(prefs.textFilterEngine.isFiltered('The End'), isFalse);
    });
  });

  test('the engine is rebuilt only when the rules change', () async {
    final first = prefs.textFilterEngine;
    expect(identical(first, prefs.textFilterEngine), isTrue);
    await prefs.hideTextEverywhere('The End');
    expect(identical(first, prefs.textFilterEngine), isFalse);
  });

  test('a custom rule survives a fresh prefs instance', () async {
    await prefs.hideTextEverywhere('The End');
    // A new instance reads the same box, which is what "in every novel" has to
    // mean: the rules are not held by the reader that wrote them.
    final reopened = ReaderPrefs();
    expect(reopened.textFilterRules, hasLength(1));
    expect(reopened.textFilterEngine.isFiltered('The End'), isTrue);
  });
}
