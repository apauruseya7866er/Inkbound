import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Undo bar the reader shows after a sentence is hidden.
///
/// It is a [SnackBar] carrying a [SnackBarAction], and on this Flutter version
/// that combination is NOT auto-dismissed — the bar stayed on screen until the
/// app was restarted. The reader therefore takes it down itself with a Timer
/// (see `novel_reader_screen._undoHideSnack`), and these tests pin both halves
/// of that: the bar says what happened and offers Undo, and an explicit hide is
/// what actually removes it.
///
/// If a future Flutter restores auto-dismissal, the second test failing is the
/// signal that the Timer can go.
void main() {
  Future<GlobalKey<ScaffoldMessengerState>> mount(WidgetTester t) async {
    final key = GlobalKey<ScaffoldMessengerState>();
    await t.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: key,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    return key;
  }

  void showUndo(ScaffoldMessengerState m) => m
    ..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(
        content: Text('Hidden everywhere: read at novelsb.com!'),
        action: SnackBarAction(label: 'Undo', onPressed: _noop),
      ),
    );

  testWidgets('the bar names what was hidden and offers the way back',
      (tester) async {
    final key = await mount(tester);
    showUndo(key.currentState!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('Hidden everywhere:'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
  });

  testWidgets('a SnackBar with an action is not dismissed by its own duration',
      (tester) async {
    // The reason the reader does not trust the default. Explicit `duration` and
    // `SnackBarBehavior.floating` were both tried and neither helps.
    final key = await mount(tester);
    showUndo(key.currentState!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.textContaining('Hidden everywhere:'), findsOneWidget);
  });

  testWidgets('an explicit hide after the delay takes it down, as the reader does',
      (tester) async {
    final key = await mount(tester);
    showUndo(key.currentState!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    Timer(const Duration(seconds: 5), () => key.currentState!.hideCurrentSnackBar());
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.textContaining('Hidden everywhere:'), findsNothing);
  });
}

void _noop() {}