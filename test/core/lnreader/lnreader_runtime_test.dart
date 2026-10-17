@Tags(['needs-device'])
library;

// These run real plugin JavaScript through flutter_js, which on Android is
// QuickJS compiled to a native library by Gradle (see flutter_js's own
// android/CMakeLists.txt). There is no host build of that library to install,
// so on a desktop test host these can only ever fail with `Failed to load
// dynamic library 'quickjs_c_bridge'`. The tag plus dart_test.yaml skips them
// there, which is what lets the host Test job be a real gate instead of a
// permanently red one; `flutter test --run-skipped` opts back in.
//
// The same engine is covered for real on a device by
// integration_test/js_runtime_test.dart.

import 'package:flutter_test/flutter_test.dart';

import 'package:watch_app/core/lnreader/lnreader_runtime.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads a plugin and drives a fetch through the outbox bridge', () async {
    final runtime = LnReaderRuntime(
      fetch: (url, init) async => const LnReaderHttpResponse(
        status: 200,
        body: '<h1>Hello</h1>',
        url: 'http://x/a',
      ),
    );

    final name = await runtime.loadPlugin('fake', _fakePlugin);
    expect(name, 'Fake');

    final result = await runtime.call('fake', 'parseNovel', ['/a']);
    expect(result, {'name': 'Hello'});

    runtime.dispose();
  });

  test(
    'a fetch failure rejects the plugin call instead of hanging to the 30s timeout',
    () async {
      final runtime = LnReaderRuntime(
        fetch: (url, init) async =>
            throw Exception('boom: connection refused'),
      );

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

      runtime.dispose();
    },
    // Well under the driver's 30s call timeout: if __rejectFetch ever stops
    // reaching the pending promise, this test times out instead of quietly
    // passing 30s slower.
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test('rebuilds the engine after dispose() instead of reusing a stale ready future', () async {
    final runtime = LnReaderRuntime(
      fetch: (url, init) async => const LnReaderHttpResponse(
        status: 200,
        body: '<h1>Hello</h1>',
        url: 'http://x/a',
      ),
    );

    await runtime.loadPlugin('fake', _fakePlugin);
    expect(await runtime.call('fake', 'parseNovel', ['/a']), {'name': 'Hello'});

    runtime.dispose();

    // Same instance, used again after dispose() — must rebuild, not hit the
    // stale _readyFuture / a null _rt.
    await runtime.loadPlugin('fake', _fakePlugin);
    expect(await runtime.call('fake', 'parseNovel', ['/a']), {'name': 'Hello'});

    runtime.dispose();
  });
}
