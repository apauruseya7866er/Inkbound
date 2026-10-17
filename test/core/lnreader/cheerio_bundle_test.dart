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
import 'package:flutter_js/flutter_js.dart';
import 'package:flutter/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('committed cheerio bundle parses HTML in QuickJS', () async {
    final bundle = await rootBundle.loadString('assets/js/lnreader_cheerio.js');
    final rt = getJavascriptRuntime(xhr: false);
    expect(rt.evaluate(bundle).isError, isFalse);
    final r = rt.evaluate(
      "var \$=loadCheerio('<a class=x href=/1>Hi</a>'); \$('.x').text()+'|'+\$('.x').attr('href');",
    );
    expect(r.stringResult, 'Hi|/1');
  });
}
