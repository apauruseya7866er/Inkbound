import 'package:hive/hive.dart';

/// One selectable splash animation.
class SplashStyleOption {
  const SplashStyleOption({required this.id, required this.label});

  /// Persisted — never rename. Matches [SplashStyle.options].
  final String id;
  final String label;
}

/// Which animation the splash plays.
///
/// Shaped like the launcher-icon picker next to it in Settings, and for the
/// same reason: the choice is persisted, so ids are permanent once shipped.
///
/// Unlike the icon picker there is no native side to disagree with — this is
/// read straight off the box at build time, so [selectedId] is the whole truth
/// and needs no reconciling.
class SplashStyle {
  SplashStyle._();

  static const String boxName = 'app_prefs';
  static const String _key = 'splashStyleId';

  /// The wordmark reveal — what the app has always shown. A fresh install is
  /// unchanged by this feature existing.
  static const String defaultId = 'wordmark';

  /// [defaultId] first, so the picker leads with what a fresh install wears.
  ///
  /// One option today. A second animated splash used to be offered here and
  /// was drawn from the upstream project's logo geometry, which is not this
  /// app's mark; it is gone rather than re-skinned. Its persisted id now falls
  /// back to [defaultId] via [selectedId], so anyone who had picked it gets the
  /// wordmark on the next launch.
  static const List<SplashStyleOption> options = [
    SplashStyleOption(id: 'wordmark', label: 'Wordmark'),
  ];

  /// Falls back to [defaultId] for anything unknown, so a build that drops an
  /// option can't leave the splash with nothing to play.
  ///
  /// MUST tolerate the box being closed. The splash is on screen *while*
  /// `initDependencies()` is still opening boxes, so this is read before the
  /// store exists — `Hive.box()` throws there, and a throw inside the splash's
  /// build is a blank screen on every cold start. Same guard `isOnboarded()`
  /// uses, for the same reason.
  static String get selectedId {
    if (!Hive.isBoxOpen(boxName)) return defaultId;
    final v = Hive.box(boxName).get(_key);
    if (v is String && options.any((o) => o.id == v)) return v;
    return defaultId;
  }

  static Future<void> select(String id) async {
    if (!options.any((o) => o.id == id)) return;
    if (!Hive.isBoxOpen(boxName)) return;
    await Hive.box(boxName).put(_key, id);
  }
}
