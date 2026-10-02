import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive/hive.dart';

import '../hive/safe_box.dart';
import 'lnreader_extension_service.dart';

/// Seeds the official LNReader plugin repository, so a fresh install has novel
/// sources without the user pasting a repo URL.
///
/// The app was always built for this — [LnReaderExtensionService.fetchIndex]
/// reads exactly the index shape LNReader publishes, and the Sources screen
/// already lists, filters and installs from a tracked repo. All it lacked was
/// anything putting a URL in the box, which left a novel-only build with an
/// empty source list on first launch.
///
/// Why the index rather than plugins shipped in the APK: LNReader's repo holds
/// 284 maintained sources (157 English) and is where upstream scraper fixes
/// land. Hand-written equivalents would be a strictly worse copy of ~3 of them,
/// frozen at whatever markup I happened to observe, with no update path. This
/// way a site that redesigns is fixed upstream and every user gets it on the
/// next install pass.
///
/// The index is committed to the `plugins/v3.0.0` branch — `.dist` is
/// gitignored on `master`, which is why it 404s there. `lang` arrives as a
/// display name ("English", "Français"), not a code.
class LnReaderSeedRepo {
  LnReaderSeedRepo._();

  /// The published index. A branch, not a tag: the branch is what the upstream
  /// build script commits its output to, and a tag would pin an index whose
  /// plugin URLs (which also live on the branch) stop being updated.
  static const String indexUrl =
      'https://raw.githubusercontent.com/LNReader/lnreader-plugins'
      '/plugins/v3.0.0/.dist/plugins.min.json';

  /// The only `lang` value installed by default. The app can hold any language;
  /// this is a first-run default, not a restriction — the Sources screen's own
  /// filter and "add repo" flow are untouched.
  static const String defaultLanguage = 'English';

  /// Hive box of tracked repo index URLs, shared with the Sources screen.
  static const String reposBoxName = 'lnreader_repos';

  /// Progress marker for the resumable first-run install.
  static const String stateBoxName = 'lnreader_seed_state';

  /// Adds [indexUrl] to the tracked repos if it isn't already there. Returns
  /// true when it was added. Idempotent, and never throws — a failure here
  /// must not stop boot, it just means the user adds a repo by hand as before.
  static Future<bool> ensureSeeded() async {
    try {
      if (!Hive.isBoxOpen(reposBoxName)) {
        await openBoxSafely<String>(reposBoxName);
      }
      final box = Hive.box<String>(reposBoxName);
      if (box.values.contains(indexUrl)) return false;
      await box.add(indexUrl);
      debugPrint('[lnreader] seeded default plugin repo');
      return true;
    } catch (e) {
      debugPrint('[lnreader] seeding the default repo failed: $e');
      return false;
    }
  }

  /// How many [language] sources from [indexUrl] are not installed at the same
  /// or a newer version.
  ///
  /// Drives the "install them" offer on the Sources screen, so the screen can
  /// say "157 available" without downloading anything just to count. Returns 0
  /// when the index cannot be reached, which is indistinguishable from
  /// "nothing to offer" — deliberate, because a count is not worth surfacing an
  /// error for and the install button simply stays absent.
  static Future<int> pendingCount(
    LnReaderExtensionService service, {
    String language = defaultLanguage,
  }) async {
    try {
      final index = await service.fetchIndex(indexUrl);
      final wanted = index
          .where((m) => m.lang.trim().toLowerCase() == language.toLowerCase())
          .where((m) => m.url.isNotEmpty && m.id.isNotEmpty)
          .toList();
      if (wanted.isEmpty) return 0;

      if (!Hive.isBoxOpen(LnReaderExtensionService.boxName)) {
        await openBoxSafely<Map>(LnReaderExtensionService.boxName);
      }
      final installed = Hive.box<Map>(LnReaderExtensionService.boxName);

      var pending = 0;
      for (final meta in wanted) {
        final existing = installed.get(meta.id);
        if (existing == null || !_isCurrent(existing['version'], meta.version)) {
          pending++;
        }
      }
      return pending;
    } catch (e) {
      debugPrint('[lnreader] pending count failed: $e');
      return 0;
    }
  }

  /// Installs every [defaultLanguage] source from [indexUrl] that isn't
  /// already installed at the same or a newer version.
  ///
  /// Returns the ids it wrote. Deliberately all-or-nothing per plugin and
  /// resumable across launches: it walks the index in order, skips what is
  /// already current, and stops at the first hard failure rather than retrying
  /// 157 times against a network that is down. A run interrupted by the app
  /// being killed simply resumes next time it is invoked, because "already
  /// installed" is read from the box rather than from in-memory progress.
  ///
  /// **Not** run at boot. Seeding the index is inline and free (the Sources
  /// screen can list the catalogue immediately), but installing ~157 plugins is
  /// ~2.3 MB of downloads and a couple of minutes of network on a fresh install,
  /// spent on sources the user may never open. It is offered from the Sources
  /// screen instead, which is also where the user can see what they are getting.
  static Future<List<String>> installLanguage(
    LnReaderExtensionService service, {
    String language = defaultLanguage,
  }) async {
    final written = <String>[];
    List<LnReaderPluginMeta> index;
    try {
      index = await service.fetchIndex(indexUrl);
    } catch (e) {
      debugPrint('[lnreader] seed index fetch failed: $e');
      return written;
    }

    final wanted = index
        .where((m) => m.lang.trim().toLowerCase() == language.toLowerCase())
        .toList();
    debugPrint(
      '[lnreader] seed: ${wanted.length} $language sources of ${index.length}',
    );

    if (!Hive.isBoxOpen(LnReaderExtensionService.boxName)) {
      await openBoxSafely<Map>(LnReaderExtensionService.boxName);
    }
    final installed = Hive.box<Map>(LnReaderExtensionService.boxName);

    for (final meta in wanted) {
      // An index entry missing a url would install an empty plugin; the
      // published index has none today, but a malformed one should not be able
      // to write junk into the box.
      if (meta.url.isEmpty || meta.id.isEmpty) continue;
      final existing = installed.get(meta.id);
      if (existing != null && _isCurrent(existing['version'], meta.version)) {
        continue;
      }
      try {
        await service.install(meta);
        written.add(meta.id);
      } catch (e) {
        // One dead site must not abandon the other 156. Log and move on.
        debugPrint('[lnreader] seed: ${meta.id} failed: $e');
      }
    }

    if (written.isNotEmpty) {
      debugPrint('[lnreader] seeded ${written.length} $language sources');
    }
    return written;
  }

  /// True when [have] is at least [want]. Unparseable or missing versions count
  /// as out of date: a source with an unknown version is better refreshed from
  /// the index than left as whatever was stored.
  static bool _isCurrent(Object? have, String want) {
    if (have is! String || have.isEmpty || want.isEmpty) return false;
    final a = _parse(have);
    final b = _parse(want);
    if (a == null || b == null) return have == want;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return true; // equal
  }

  /// Dotted numeric version -> zero-padded comparable list. "2.2.1" and "2.10.0"
  /// must not compare as equal, and "2.2" must not beat "2.2.1".
  static List<int>? _parse(String v) {
    final parts = v.trim().split(RegExp(r'[.+-]'));
    if (parts.isEmpty) return null;
    final out = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null) return null;
      // Pad so a shorter version sorts below a longer one that shares its
      // prefix (1.2.9 < 1.2.10, and 1.2 < 1.2.1).
      out.add(n);
    }
    while (out.length < 4) {
      out.add(0);
    }
    return out;
  }
}
