// The review page with the sample review: a thread opened from the inbox,
// then a question sent to Claude on it. Needs the macOS fonts (the sample
// rows overflow in the test font), so it skips elsewhere.
import 'package:deck/core/review/review.dart';
import 'package:deck/dev/fixtures.dart';
import 'package:deck/main.dart';
import 'package:deck/state/reviews.dart';
import 'package:deck/ui/review/thread_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../golden/fonts.dart';

late Review _review;

/// Saves a question like the review store does: on the thread, waiting on Claude.
class _Reviews extends Reviews {
  @override
  Future<void> reply(ReviewKey key, String threadId, String body) async {
    _review = _review.copyWith(
      threads: [
        for (final t in _review.threads)
          t.id == threadId
              ? t.copyWith(
                  waiting: true,
                  messages: [
                    ...t.messages,
                    Message(id: 'm-new', author: 'user', body: body),
                  ],
                )
              : t,
      ],
    );
    reviewChanged(key.project, key.id);
  }
}

void main() {
  late bool fonts;
  setUpAll(() async => fonts = await loadFonts());

  Future<void> open(WidgetTester t, Review r) async {
    _review = r;
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    bool fixture(Object o) {
      try {
        final from = (o as dynamic).from;
        return from == reviewProvider;
      } catch (_) {
        return false;
      }
    }

    await t.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides(sampleConfig, sampleBoard()).where((o) => !fixture(o)),
          reviewsProvider.overrideWith(_Reviews.new),
          reviewProvider.overrideWith((ref, key) async {
            ref.watch(reviewsProvider);
            return _review;
          }),
        ],
        child: const DeckApp(),
      ),
    );
    await t.pump(const Duration(milliseconds: 100));
    GoRouter.of(t.element(find.byType(Scaffold).first)).go('/project/vpn-ios/review/gitlab-412');
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Finder cardOf(String id) => find.byWidgetPredicate((w) => w is ThreadCard && w.thread.id == id);

  Future<void> openFromInbox(WidgetTester t, String id) async {
    t.widget<ThreadInbox>(find.byType(ThreadInbox)).onOpen(_review.threads.firstWhere((x) => x.id == id));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('a question sent on a thread opened from the inbox shows on its card', (t) async {
    if (!fonts) return markTestSkipped('macOS fonts not found');
    await open(t, sampleReview());
    await openFromInbox(t, 't1');
    expect(cardOf('t1'), findsOneWidget);
    await t.tap(find.descendant(of: cardOf('t1'), matching: find.text('Ask Claude…')));
    await t.pump();
    await t.enterText(find.descendant(of: cardOf('t1'), matching: find.byType(TextField)), 'Why two deletes?');
    await t.tap(find.descendant(of: cardOf('t1'), matching: find.text('Send')));
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.descendant(of: cardOf('t1'), matching: find.textContaining('Why two deletes?')), findsOneWidget);
    expect(find.descendant(of: cardOf('t1'), matching: find.text('Waiting for Claude')), findsOneWidget);
  });

  testWidgets('a thread in a file folded as viewed opens the file', (t) async {
    if (!fonts) return markTestSkipped('macOS fonts not found');
    final r = sampleReview();
    final path = r.threads.firstWhere((x) => x.id == 't1').anchor!.path;
    await open(t, r.copyWith(viewed: {...r.viewed, path: 'head'}));
    expect(cardOf('t1'), findsNothing);
    await openFromInbox(t, 't1');
    expect(cardOf('t1').hitTestable(), findsOneWidget);
  });
}
