// The bar itself is dead in a novel-only build — `root_shell.dart` hides it and
// the centre FAB with it — but the widget is still compiled and still the only
// place the choice list is filtered, so what it renders is worth pinning: the
// one exposed mode, and nothing else. The old "four modes and reports the pick"
// case is gone with the three choices it counted.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/shell/mode_bar.dart';

void main() {
  testWidgets('offers the one exposed mode and reports the pick', (t) async {
    ContentMode? mode;
    StreamKind? kind;
    await t.pumpWidget(MaterialApp(home: Scaffold(
      body: ModeBar(
        open: true,
        current: (ContentMode.novel, StreamKind.anime),
        onPicked: (m, k) { mode = m; kind = k; },
      ),
    )));
    expect(find.text('Novel'), findsOneWidget);
    // The choices this build can't enter are not drawn at all.
    expect(find.text('Anime'), findsNothing);
    expect(find.text('Movie/TV'), findsNothing);
    expect(find.text('Manga'), findsNothing);
    expect(find.text('Sources'), findsNothing);
    expect(find.text('Streaming'), findsNothing);
    await t.tap(find.text('Novel'));
    expect(mode, ContentMode.novel);
    expect(kind, StreamKind.anime);
  });

  testWidgets('closed bar ignores taps', (t) async {
    var picked = 0;
    await t.pumpWidget(MaterialApp(home: Scaffold(
      body: ModeBar(
        open: false,
        current: (ContentMode.novel, StreamKind.anime),
        onPicked: (_, _) => picked++,
      ),
    )));
    await t.tap(find.text('Novel'), warnIfMissed: false);
    expect(picked, 0);
  });
}
