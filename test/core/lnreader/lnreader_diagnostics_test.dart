import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/lnreader/lnreader_diagnostics.dart';

/// The diagnostics are only useful if they can be pasted into a public bug
/// report, so what they must never contain is the thing under test. These are
/// the tests that matter most in this file: a redaction regression leaks the
/// reader's session into a log they meant to share.
void main() {
  group('a logged URL keeps its path and loses its query', () {
    test('a query string is dropped whole', () {
      expect(
        LnReaderDiag.redactUrl(
          'https://www.webnovel.com/novel/the-alpha/123456?token=secret123',
        ),
        'https://www.webnovel.com/novel/the-alpha/123456',
      );
    });

    test('a signed image URL loses its signature', () {
      // Signed CDN URLs carry an account-bound signature in the query. Keeping
      // the path is fine; keeping that is not.
      final out = LnReaderDiag.redactUrl(
        'https://cdn.example.com/cover.jpg?Expires=1&Signature=abc&Key-Pair-Id=x',
      );
      expect(out, 'https://cdn.example.com/cover.jpg');
      expect(out, isNot(contains('Signature')));
      expect(out, isNot(contains('Expires')));
    });

    test('a fragment is dropped too', () {
      expect(
        LnReaderDiag.redactUrl('https://x.com/a/b#chapter-4'),
        'https://x.com/a/b',
      );
    });

    test('the path survives, because it names the chapter', () {
      // "Which chapter request failed" is the question being asked, and for
      // these hosts the chapter id is in the path.
      expect(
        LnReaderDiag.redactUrl('https://www.webnovel.com/novel/x/987?a=1'),
        contains('/novel/x/987'),
      );
    });

    test('an unparseable or relative URL is reported, not passed through', () {
      // Logging a raw malformed string is how a body or a token ends up in a log
      // by accident, so it is replaced rather than sanitised.
      expect(LnReaderDiag.redactUrl('::::not a url::::'), '<unparseable-url>');
      expect(LnReaderDiag.redactUrl('/relative/path'), '<relative-url>');
    });
  });

  group('headers are named, never valued', () {
    test('only the sorted lowercased names are reported', () {
      final out = LnReaderDiag.headerNames({
        'User-Agent': 'Mozilla/5.0',
        'Referer': 'https://www.webnovel.com',
        'accept-language': 'en-US',
      });
      expect(out, 'accept-language,referer,user-agent');
    });

    test('no header value can reach the output', () {
      final secrets = {
        'Cookie': 'session=abcdef123456; cf_clearance=zzz',
        'Set-Cookie': 'cf_clearance=zzz; HttpOnly',
        'Authorization': 'Bearer eyJhbGciOiJIUzI1NiJ9.secret',
      };
      final out = LnReaderDiag.headerNames(secrets);
      // The names are reported, because knowing a cookie came back is useful.
      expect(out, contains('cookie'));
      expect(out, contains('authorization'));
      // None of the values, which are the part that must never be logged.
      for (final value in secrets.values) {
        expect(out, isNot(contains(value)));
      }
      expect(out, isNot(contains('abcdef123456')));
      expect(out, isNot(contains('zzz')));
      expect(out, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
    });

    test('no headers at all is not an error', () {
      expect(LnReaderDiag.headerNames(const {}), '-');
    });
  });

  group('a returned value is described, not reproduced', () {
    test('an empty list is the case worth catching', () {
      // A Cloudflare page, a login wall and a moved selector all arrive here as
      // an empty list, and each needs a different fix.
      final (kind, detail) = LnReaderDiag.describe(const <Object?>[]);
      expect(kind, 'empty');
      expect(detail, 'list(0)');
    });

    test('a non-empty list reports only its length', () {
      final (kind, detail) = LnReaderDiag.describe([
        {'name': 'The Alpha', 'path': 'novel/x/1'},
        {'name': 'The Beta', 'path': 'novel/x/2'},
      ]);
      expect(kind, 'ok');
      expect(detail, 'list(2)');
    });

    test('a map reports its key names only', () {
      final (kind, detail) = LnReaderDiag.describe({
        'name': 'A title',
        'summary': 'A long description of the book.',
      });
      expect(kind, 'ok');
      expect(detail, contains('name'));
      expect(detail, contains('summary'));
      expect(detail, isNot(contains('A title')));
      expect(detail, isNot(contains('long description')));
    });

    test('a long map is truncated so a log line stays one line', () {
      final wide = {for (var i = 0; i < 40; i++) 'key$i': 'value$i'};
      final (_, detail) = LnReaderDiag.describe(wide);
      expect(detail, contains('…'));
      expect(detail!.length, lessThan(80));
      expect(detail, isNot(contains('value39')));
    });

    test('an empty string body is empty, not ok', () {
      expect(LnReaderDiag.describe('   '), ('empty', 'string(0)'));
    });

    test('null and unexpected shapes are named', () {
      expect(LnReaderDiag.describe(null).$1, 'null');
      expect(LnReaderDiag.describe(42).$1, 'unexpected');
    });
  });

  group('an id mismatch is called out', () {
    test('a matching id logs nothing alarming', () {
      // Behaviour is the debugPrint, so what is asserted here is that the
      // decision function agrees - see _identityMismatches below.
      expect(
        LnReaderDiag.identityMismatch('webnovel', 'webnovel'),
        isFalse,
      );
    });

    test('a plugin whose own id differs from the index is flagged', () {
      // This is the case that makes a plugin's setting look like it resets on
      // every restart while nothing is wrong with the setting itself.
      expect(
        LnReaderDiag.identityMismatch('WebNovel', 'webnovel'),
        isTrue,
      );
    });

    test('a plugin with no id of its own is not a mismatch', () {
      expect(LnReaderDiag.identityMismatch('webnovel', null), isFalse);
    });
  });
}