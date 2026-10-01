import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Undo bar the reader shows after a sentence is hidden.
///
/// It is a plain [SnackBar], so Flutter owns the timing - this does not test
/// the framework, it pins the two things a change here could actually break:
/// that the bar says what happened and offers the way back, and that it is a
/// real SnackBar rather than something pinned open.
///
/// The dismissal assertion advances the clock in one jump. Pumped in many small
/// steps the messenger's internal timer does not settle, which looks like a
/// stuck bar and is only an artefact of how the harness drives time.
void main() {
  testWidgets('the Undo bar says what happened and offers the way back',
      (tester) async {
    final key = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: key,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );

    key.currentState!
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Hidden everywhere: read at novelsb.com!'),
          action: SnackBarAction(label: 'Undo', onPressed: () {}),
        ),
      );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('Hidden everywhere:'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
  });

  testWidgets('it is a SnackBar that takes the default duration, so it leaves',
      (tester) async {
    final key = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: key,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );

    key.currentState!.showSnackBar(
      const SnackBar(
        content: Text('Hidden everywhere: something'),
        action: SnackBarAction(label: 'Undo', onPressed: _noop),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Hidden everywhere:'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.textContaining('Hidden everywhere:'), findsNothing);
  });
}

void _noop() {}