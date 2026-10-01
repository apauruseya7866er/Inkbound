import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/reading/read_store.dart';
import 'package:watch_app/core/privacy/incognito_mode.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('read_store');
    Hive.init(dir.path);
    await ReadStore.init();
    IncognitoMode.notifier.value = false;
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('save/get round-trip, keyed per chapter', () async {
    final s = ReadStore();
    await s.save('js:m', 'show1', 'ch1', pos: 3, total: 20);
    expect(s.get('js:m', 'show1', 'ch1'), (pos: 3, total: 20));
    expect(s.get('js:m', 'show1', 'ch2'), isNull);
  });

  test('finished: manga last page', () async {
    final s = ReadStore();
    await s.save('js:m', 'show1', 'ch1', pos: 19, total: 20);
    expect(s.finished('js:m', 'show1', 'ch1'), isTrue);
    await s.save('js:m', 'show1', 'ch2', pos: 10, total: 20);
    expect(s.finished('js:m', 'show1', 'ch2'), isFalse);
  });

  test('finished: novel ≥95% scroll', () async {
    final s = ReadStore();
    await s.save('js:n', 'book', 'ch1', pos: 960, total: 1000);
    expect(s.finished('js:n', 'book', 'ch1'), isTrue);
  });

  test('incognito: save is a no-op while on', () async {
    final s = ReadStore();
    IncognitoMode.notifier.value = true;
    await s.save('js:m', 'show1', 'ch1', pos: 3, total: 20);
    expect(s.get('js:m', 'show1', 'ch1'), isNull);
    IncognitoMode.notifier.value = false;
  });

  // The reader calls this on the way out of the app, and it is the whole reason
  // a chapter read today reopens in the right place tomorrow: `save` only hands
  // the record to Hive, which writes the file on its own schedule.
  test('flush gets a saved position onto the disk', () async {
    final s = ReadStore();
    await s.save('js:n', 'book', 'ch1', pos: 420, total: 1000);
    await s.flush();

    // A separate Hive instance over the same directory is the only honest way to
    // ask "is it really on disk" — the open box would answer from memory, which
    // is exactly the state that used to be lost.
    final file = File('${dir.path}/${ReadStore.boxName}.hive');
    expect(file.existsSync(), isTrue);

    await Hive.close();
    Hive.init(dir.path);
    await ReadStore.init();
    final reopened = ReadStore();
    expect(reopened.get('js:n', 'book', 'ch1'), (pos: 420, total: 1000));
  });
}
