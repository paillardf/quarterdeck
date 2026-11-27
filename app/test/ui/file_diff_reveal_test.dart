// A thread opened from the inbox opens the file and hunk that hide its line.
import 'package:deck/dev/review_fixtures.dart';
import 'package:deck/ui/review/file_diff.dart';
import 'package:deck/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final file = sampleReviewDiff().files.firstWhere((f) => f.hunks.isNotEmpty);
  final line = file.hunks.first.lines.map((l) => l.newLine).whereType<int>().first;

  Widget page({({String side, int line, Key card, int seq})? reveal}) => MaterialApp(
    theme: deckTheme(Brightness.light),
    home: Scaffold(
      body: CustomScrollView(
        slivers: [
          FileDiffView(
            file: file,
            viewed: true,
            reveal: reveal,
            below: {
              ('new', line): [const Text('the card', key: ValueKey('card'))],
            },
          ),
        ],
      ),
    ),
  );

  testWidgets('a viewed file opens on reveal, and again on a new seq', (tester) async {
    await tester.pumpWidget(page());
    expect(find.text('the card'), findsNothing);

    await tester.pumpWidget(page(reveal: (side: 'new', line: line, card: const ValueKey('card'), seq: 1)));
    expect(find.text('the card'), findsOneWidget);

    // Folded again by hand, then the same thread opened again.
    await tester.tap(find.byIcon(Icons.expand_more).first);
    await tester.pump();
    expect(find.text('the card'), findsNothing);
    await tester.pumpWidget(page(reveal: (side: 'new', line: line, card: const ValueKey('card'), seq: 2)));
    expect(find.text('the card'), findsOneWidget);
  });
}
