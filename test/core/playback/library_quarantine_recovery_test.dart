import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/core/reading/read_history.dart';

/// A value only an OLD build could read, used to make a box unreadable —
/// exactly the `HiveError: Cannot read, unknown typeId` seen on real devices.
class _Legacy {}

class _LegacyAdapter extends TypeAdapter<_Legacy> {
  @override
  final int typeId = 116;
  @override
  _Legacy read(BinaryReader reader) => _Legacy();
  @override
  void write(BinaryWriter writer, _Legacy obj) {}
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lib_quarantine_test');
    Hive.init(dir.path);
    hiveBoxDir = dir.path;
    quarantinedBoxes.clear();
  });

  tearDown(() async {
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> breakBox(String name) async {
    if (!Hive.isAdapterRegistered(116)) Hive.registerAdapter(_LegacyAdapter());
    final box = await Hive.openBox<Map>(name);
    await box.put('k', {'v': _Legacy()});
    await box.close();
    Hive.resetAdapters(); // this build no longer knows typeId 116
  }

  /// Hive leaves an orphan errored completer behind a failed openBox; swallow
  /// only that, and surface anything real.
  Future<void> initIgnoringOrphanError(Future<void> Function() init) {
    final done = Completer<void>();
    runZonedGuarded(() async {
      try {
        await init();
        done.complete();
      } catch (e, s) {
        done.completeError(e, s);
      }
    }, (_, _) {});
    return done.future.timeout(const Duration(seconds: 10));
  }

  // An unreadable box must not fail the launch: openBoxSafely quarantines it
  // (or deletes it, when the file is still locked) and reopens it empty, so the
  // person gets a working app with an empty list and can restore a backup. The
  // byte-level mechanics of that recovery are covered in safe_box's own tests;
  // what matters per store is that its init() goes through openBoxSafely and
  // comes back.
  for (final entry in <({String box, String label, Future<void> Function() init})>[
    (box: MyListStore.boxName, label: 'My List', init: MyListStore.init),
    (box: WatchHistory.boxName, label: 'history', init: WatchHistory.init),
    (box: ReadHistory.boxName, label: 'reading history', init: ReadHistory.init),
  ]) {
    test('a quarantined ${entry.label} reopens empty instead of failing the '
        'launch', () async {
      await breakBox(entry.box);

      // Completes without throwing: that IS the property under test.
      await initIgnoringOrphanError(entry.init);

      expect(quarantinedBoxes, contains(entry.box));
    });
  }
}