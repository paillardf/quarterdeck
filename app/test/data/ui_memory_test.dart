import 'dart:io';

import 'package:deck/data/ui_memory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ui_memory'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('starts on the board when nothing is saved', () {
    final m = UiMemory(File('${dir.path}/ui.json'));
    expect(m.location, '/');
    expect(m.panel, isFalse);
    expect(m.places, isEmpty);
    expect(m.summaryNote, isTrue);
  });

  test('a new start reads the screen, the panel and each project section', () {
    final f = File('${dir.path}/ui.json');
    UiMemory(f)
      ..setLocation(Uri.parse('/project/vpn-ios?tab=mrs'))
      ..setLocation(Uri.parse('/project/backend?feature=auth'))
      ..setLocation(Uri.parse('/project/backend/review/gitlab-4'))
      ..setPanel(true);
    final m = UiMemory(f);
    expect(m.location, '/project/backend/review/gitlab-4');
    expect(m.panel, isTrue);
    expect(m.places, {'vpn-ios': 'tab=mrs', 'backend': 'feature=auth'});
  });

  test('an unreadable file starts on the board', () {
    final f = File('${dir.path}/ui.json')..writeAsStringSync('{not json');
    expect(UiMemory(f).location, '/');
  });

  test('the summary note choice is kept for the next start', () {
    final f = File('${dir.path}/ui.json');
    UiMemory(f).setSummaryNote(false);
    expect(UiMemory(f).summaryNote, isFalse);
  });
}
