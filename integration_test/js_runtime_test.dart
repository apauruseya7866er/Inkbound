import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:watch_app/core/lnreader/lnreader_runtime.dart';

/// End-to-end checks of the embedded JavaScript engine on a real device.
///
/// ### Why this file exists
///
/// The novel source system runs every scraper inside `flutter_js`, and on Android
/// that package is backed by **QuickJS compiled to a native library** — the same
/// `.so` Gradle builds from `flutter_js`'s own `android/CMakeLists.txt`. There is
/// no host build of it, so roughly thirty of the Dart tests under
/// `test/core/lnreader/` and `test/core/provider/` can only ever run where that
/// library exists. On a desktop test host `flutter_js` falls back to a pure-Dart
/// FFI path that needs a `quickjs_c_bridge` binary nobody builds, so those tests
/// fail on every developer machine and on the Linux CI runner with
/// `Failed to load dynamic library 'quickjs_c_bridge'`.
///
/// This is the other half of that coverage, and the only place it can live: on a
/// device the library is real, so the engine, the committed cheerio bundle and
/// the LNReader plugin runtime are all exercised for real rather than skipped.
///
/// ### Running them
///
/// Needs x86_64 native libs, which this project strips from every build as
/// emulator-only bloat (see the `includeEmulatorAbis` gate in
/// `android/app/build.gradle.kts`). Add this to `android/local.properties` to
/// run on an emulator:
///
/// ```properties
/// includeEmulatorAbis=true
/// ```
///
/// ```sh
/// flutter test integration_test/js_runtime_test.dart -d <device>
/// ```
Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('the native engine', () {
    testWidgets('evaluates JavaScript at all', (tester) async {
      // The bare minimum that proves the native bridge loaded. Everything below
      // is worthless if this throws, so it is asserted first and on its own:
      // "the library is missing" and "our code is wrong" are different bugs
      // and should not be reported as the same red test.
      final rt = getJavascriptRuntime(xhr: false);
      final r = rt.evaluate('1 + 2');
      expect(r.isError, isFalse);
      expect(r.stringResult, '3');
    });

    testWidgets('reports a syntax error instead of swallowing it', (
      tester,
    ) async {
      // A runtime that returned an error string for everything would also pass
      // the test above, so the failure path is checked too.
      final rt = getJavascriptRuntime(xhr: false);
      expect(rt.evaluate('this is not javascript').isError, isTrue);
    });
  });

  group('the committed cheerio bundle', () {
    // Port of test/core/lnreader/cheerio_bundle_test.dart, which cannot run on a
    // host. The bundle is what every LNReader scraper parses with, so a broken
    // one means every novel source silently returns empty text.
    testWidgets('parses HTML', (tester) async {
      final bundle = await rootBundle.loadString('assets/js/lnreader_cheerio.js');
      final rt = getJavascriptRuntime(xhr: false);
      expect(rt.evaluate(bundle).isError, isFalse);

      final r = rt.evaluate(
        "var \$=loadCheerio('<a class=x href=/1>Hi</a>'); "
        "\$('.x').text()+'|'+\$('.x').attr('href');",
      );
      expect(r.stringResult, 'Hi|/1');
    });
  });

  group('the LNReader plugin runtime', () {
    // Ports the heart of test/core/lnreader/lnreader_runtime_test.dart. This is
    // the path a real novel scraper takes: CommonJS plugin loaded into the
    // harness, a fetch pushed out to Dart and answered, then the parsed value
    // handed back. The fetch is injected, so this exercises the runtime and the
    // outbox bridge without touching the network.
    testWidgets('loads a plugin and drives a fetch through the outbox bridge', (
      tester,
    ) async {
      final runtime = LnReaderRuntime(
        fetch: (url, init) async => const LnReaderHttpResponse(
          status: 200,
          body: '<h1>Hello</h1>',
          url: 'http://x/a',
        ),
      );
      addTearDown(runtime.dispose);

      final name = await runtime.loadPlugin('fake', _fakePlugin);
      expect(name, 'Fake');

      final result = await runtime.call('fake', 'parseNovel', ['/a']);
      expect(result, {'name': 'Hello'});
    });

    testWidgets('a failing fetch rejects the call instead of hanging', (
      tester,
    ) async {
      // The 30s timeout this guards against is exactly what a broken outbox
      // looks like from a reader's side: the chapter just spins. Worth
      // pinning on a real device, where the event loop is a real one.
      final runtime = LnReaderRuntime(
        fetch: (url, init) async => throw Exception('boom: connection refused'),
      );
      addTearDown(runtime.dispose);

      await runtime.loadPlugin('fake', _fakePlugin);

      await expectLater(
        runtime.call('fake', 'parseNovel', ['/a']),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('boom: connection refused'),
          ),
        ),
      );
    });
  });
}

/// A scraper shaped like the ones LNReader plugins actually ship: it requires
/// the injected `fetch`, calls it, and parses the response with cheerio.
const _fakePlugin = '''
exports.default = {
  name: 'Fake',
  parseNovel: function (path) {
    var fetchApi = require('@libs/fetch').fetchApi;
    return fetchApi('http://x' + path).then(function (r) { return r.text(); }).then(function (html) {
      var \$ = require('cheerio').load(html);
      return { name: \$('h1').text() };
    });
  },
};
''';
