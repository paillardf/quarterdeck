// The publish dialog's choices must reach the preview: a setState given a
// Future once threw on every click.
import 'dart:async';

import 'package:deck/core/review/publish_plan.dart';
import 'package:deck/core/review/review.dart';
import 'package:deck/dev/review_fixtures.dart';
import 'package:deck/ui/review/publish_dialog.dart';
import 'package:deck/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the verdict and the summary checkbox reload the preview, without errors', (t) async {
    final r = sampleReview();
    final calls = <String>[];
    await t.pumpWidget(
      MaterialApp(
        theme: deckTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => PublishDialog(
                  mr: r.mr!,
                  preview: (v, s) async {
                    calls.add('$v $s');
                    return PublishPreview(roundNumber: 1, posting: const <Thread>[], skipped: const [], replies: 0, summary: s ? 'sum' : null);
                  },
                  publish: (_, _) => Completer<PublishResult>().future,
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    await t.tap(find.text('Approve'));
    await t.pumpAndSettle();
    await t.tap(find.byType(Checkbox));
    await t.pumpAndSettle();
    expect(calls, ['comment true', 'approve true', 'approve false']);
    expect(t.takeException(), isNull);
  });

  testWidgets('the summary note starts as last left, and a click reports the new choice', (t) async {
    final r = sampleReview();
    final calls = <String>[], kept = <bool>[];
    await t.pumpWidget(
      MaterialApp(
        theme: deckTheme(Brightness.light),
        home: Scaffold(
          body: PublishDialog(
            mr: r.mr!,
            summary: false,
            onSummary: kept.add,
            preview: (v, s) async {
              calls.add('$v $s');
              return PublishPreview(roundNumber: 1, posting: const <Thread>[], skipped: const [], replies: 0, summary: s ? 'sum' : null);
            },
            publish: (_, _) => Completer<PublishResult>().future,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(t.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    await t.tap(find.byType(Checkbox));
    await t.pumpAndSettle();
    expect(calls, ['comment false', 'comment true']);
    expect(kept, [true]);
  });
}
