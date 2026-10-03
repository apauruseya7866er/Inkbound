import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Profile dock tab *is* the settings screen, and it builds its rows from a
/// single `List<_SettingsEntry>` literal. Every `subtitle:` in that literal is
/// therefore evaluated the moment the tab opens, not when a row is tapped.
///
/// That makes an unguarded `sl<T>()` inside it a single point of failure for the
/// whole screen: if `T` was never registered, get_it throws while the list is
/// being constructed and the tab renders blank. This is not hypothetical - the
/// released 3.0.0 build shipped exactly that, losing the Profile tab entirely,
/// because one row read `CloudflareBypassPrefs` while its injector registration
/// had never been committed.
///
/// This test pairs the two files that have to agree. It cannot prove the app
/// registers everything at runtime, but it does prove the Profile tab never
/// dereferences a service the injector does not register - which is the failure
/// that produces a blank screen rather than a visible error.
void main() {
  const injectorPath = 'lib/core/di/injector.dart';
  const settingsPath = 'lib/features/settings/settings_screen.dart';

  /// Types the injector hands to get_it.
  Set<String> readRegisteredTypes() {
    final source = File(injectorPath).readAsStringSync();
    return RegExp(
      r'sl\.register(?:LazySingleton|Singleton|Factory)<([A-Za-z0-9_]+)>',
    )
        .allMatches(source)
        .map((m) => m.group(1)!)
        .toSet();
  }

  /// The body of `_buildSettingsEntries`, brace-matched from its signature.
  ///
  /// Only this function is checked: `onTap` closures elsewhere in the file run
  /// lazily and a throw inside one is a bad row, not a blank screen.
  String readEagerEntryBuilder() {
    final source = File(settingsPath).readAsStringSync();
    final signature = source.indexOf('List<_SettingsEntry> _buildSettingsEntries(');
    expect(signature, isNot(-1), reason: '_buildSettingsEntries signature not found');

    final open = source.indexOf('{', signature);
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      final ch = source[i];
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) return source.substring(open + 1, i);
      }
    }
    fail('unbalanced braces in _buildSettingsEntries');
  }

  group('Profile tab dependency wiring', () {
    test('injects a plausible set of services', () {
      // Guards the parser itself: if the regex ever stops matching, the test
      // below would vacuously pass with an empty set.
      expect(readRegisteredTypes().length, greaterThan(50));
    });

    test('every eagerly-built settings row reads a registered service', () {
      final registered = readRegisteredTypes();
      final body = readEagerEntryBuilder();

      // An occurrence is safe if it is guarded by isRegistered on the same
      // logical expression; those are the established pattern in this file
      // (see _providerPrefs) and cost one row rather than the screen.
      final guarded = RegExp(
        r'sl\.isRegistered<([A-Za-z0-9_]+)>\(\)',
      ).allMatches(body).map((m) => m.group(1)!).toSet();

      final unguarded = RegExp(
        r'(?<!isRegistered<)\bsl<([A-Za-z0-9_]+)>\(\)',
      ).allMatches(body).map((m) => m.group(1)!).toSet();

      final missing = unguarded
          .difference(registered)
          .difference(guarded)
          .toList()
        ..sort();

      expect(
        missing,
        isEmpty,
        reason:
            'These services are dereferenced while the Profile tab builds its '
            'rows, but are not registered in $injectorPath and not guarded with '
            'isRegistered. A missing registration throws here and blanks the '
            'whole tab:\n  ${missing.join('\n  ')}',
      );
    });

    test('the Cloudflare bypass row is wired to a registered service', () {
      // The specific regression, kept explicit so the fix cannot be undone by
      // removing the row's guard without also restoring the registration.
      expect(
        readRegisteredTypes(),
        contains('CloudflareBypassPrefs'),
        reason:
            'settings_screen.dart renders a Cloudflare bypass row. Its service '
            'must be registered or that row throws and blanks the Profile tab.',
      );
    });
  });
}