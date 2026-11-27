// A thread opened from the inbox: the page jumps straight to its card, deep
// in a long file under other long files, rows on the way never built.
import 'package:deck/core/review/diff.dart';
import 'package:deck/ui/review/file_diff.dart';
import 'package:deck/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

DiffFile _file(String path, int n) => DiffFile(
  oldPath: path,
  newPath: path,
  path: path,
  status: 'added',
  additions: n,
  deletions: 0,
  hunks: [
    Hunk(
      header: '@@ -0,0 +1,$n @@',
      oldStart: 0,
      oldCount: 0,
      newStart: 1,
      newCount: n,
      lines: [for (var i = 1; i <= n; i++) DiffLine(type: lineAdd, content: 'final v$i = $i;', newLine: i)],
    ),
  ],
);

void main() {
  final files = [for (var i = 0; i < 5; i++) _file('lib/f$i.dart', 600)];

  testWidgets('jumps to a card at the end of the last file in one go', (t) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    Widget page(({String side, int line, Key card, int seq})? reveal) => MaterialApp(
      theme: deckTheme(Brightness.light),
      home: Scaffold(
        body: CustomScrollView(
          controller: scroll,
          slivers: [
            for (final f in files)
              FileDiffView(
                file: f,
                reveal: f == files.last ? reveal : null,
                below: f == files.last
                    ? {
                        ('new', 590): [const SizedBox(key: ValueKey('t1'), height: 120, child: Text('the card'))],
                      }
                    : const {},
              ),
          ],
        ),
      ),
    );
    await t.pumpWidget(page(null));
    expect(find.text('the card'), findsNothing);
    final offsets = <double>[];
    scroll.addListener(() => offsets.add(scroll.offset));

    await t.pumpWidget(page((side: 'new', line: 590, card: const ValueKey('t1'), seq: 1)));
    await t.pump();
    expect(find.text('the card').hitTestable(), findsOneWidget);
    // At most a jump and the correction of the estimate: no stepping down the page.
    expect(offsets.length, lessThanOrEqualTo(3), reason: '$offsets');
    expect(find.text('final v1 = 1;'), findsNothing);
  });
}
