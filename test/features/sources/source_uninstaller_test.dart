import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/source_uninstaller.dart';

/// Uninstalling from the Source health screen picks the delete path by SOURCE ID
/// now, rather than sending the user to whichever screen owns the source. So the
/// invariant that matters has moved: every id family has to reach ITS OWN
/// ecosystem's delete, and the two uninstallable-by-nothing ids have to be
/// refused rather than sent down a path that would find nothing to remove.
///
/// Getting this wrong is quiet. Send a Mihon source down the JS-provider path
/// and it deletes a registry key that never existed — the source stays, and the
/// UI reports success.
void main() {
  group('each id family reaches its own ecosystem delete', () {
    test('cs: → CloudStream', () {
      expect(
        SourceUninstaller.ecosystemOf('cs:foo'),
        SourceEcosystem.cloudStream,
      );
    });

    test('ani: → Aniyomi', () {
      expect(SourceUninstaller.ecosystemOf('ani:12'), SourceEcosystem.aniyomi);
    });

    test('mihon: → Mihon', () {
      expect(SourceUninstaller.ecosystemOf('mihon:12'), SourceEcosystem.mihon);
    });

    test('lnr: → LNReader', () {
      expect(SourceUninstaller.ecosystemOf('lnr:x'), SourceEcosystem.lnReader);
    });

    test('an unprefixed id is a JS provider', () {
      // JS provider ids carry no prefix, so this is the fallback. If a new
      // ecosystem ever ships an unprefixed id it would land here wrongly —
      // which is exactly why the prefixes above are pinned.
      expect(
        SourceUninstaller.ecosystemOf('hianime'),
        SourceEcosystem.jsProvider,
      );
    });
  });

  group('what cannot be uninstalled', () {
    test('Z-Mode has nothing installed behind it', () {
      // A meta-source that resolves across the others. Offering "uninstall"
      // would promise something nothing can do.
      expect(SourceUninstaller.canUninstall('zm'), isFalse);
    });

    test('an empty id is refused rather than routed', () {
      expect(SourceUninstaller.canUninstall(''), isFalse);
    });

    test('everything real is uninstallable', () {
      for (final id in ['cs:a', 'ani:1', 'mihon:1', 'lnr:a', 'hianime']) {
        expect(SourceUninstaller.canUninstall(id), isTrue, reason: id);
      }
    });
  });

  test('a mihon id is not mistaken for a plain one', () {
    // 'mihon:' must be checked before the unprefixed JS fallback, or every Mihon
    // source would try to delete a provider-registry entry that was never there
    // — a silent no-op reported as success.
    expect(
      SourceUninstaller.ecosystemOf('mihon:9'),
      isNot(SourceEcosystem.jsProvider),
    );
  });

  test('a versioned CloudStream id still routes to CloudStream', () {
    // CS ids carry an `@version@repoTag` suffix, and the health screen passes
    // that id through untouched. Routing must read the prefix, not match the
    // whole string.
    expect(
      SourceUninstaller.ecosystemOf('cs:myplugin@1.2@3f0a1b'),
      SourceEcosystem.cloudStream,
    );
  });
}
