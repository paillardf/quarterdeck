import 'package:deck/actions/launcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an outside terminal gets the Claude folder Deck reads, so a resumed session writes there', () {
    expect(
      terminalLine('/work/acme', "claude --resume 'abc'", "/opt/acme/claude it's"),
      "cd '/work/acme' && export CLAUDE_CONFIG_DIR='/opt/acme/claude it'\\''s' && claude --resume 'abc'",
    );
  });

  test('without a configured folder the line leaves claude on its default', () {
    expect(terminalLine('/work/acme', 'claude', null), "cd '/work/acme' && claude");
  });
}
