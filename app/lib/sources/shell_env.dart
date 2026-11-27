// A desktop app started from the Dock or a launcher does not get the PATH of
// the user's shell, so `npx` and `claude` are not found. Ask the login shell
// once for its environment (PATH and CLAUDE_CONFIG_DIR).
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

Future<Map<String, String>>? _cached;

/// Set by the Claude Code session that started Deck, when it was started from
/// one. A `claude` that inherits them thinks it is a child session and saves
/// no transcript.
const _claudeSession = {
  'CLAUDECODE',
  'CLAUDE_PID',
  'CLAUDE_EFFORT',
  'CLAUDE_CODE_CHILD_SESSION',
  'CLAUDE_CODE_SESSION_ID',
  'CLAUDE_CODE_SESSION_ATTENDED',
  'CLAUDE_CODE_ENTRYPOINT',
  'CLAUDE_CODE_EXECPATH',
  'CLAUDE_CODE_MESSAGING_SOCKET',
  'CLAUDE_CODE_MESSAGING_TOKEN',
};

/// True when [command] is a file on the login shell's PATH, or a path to one.
Future<bool> onPath(String command) async {
  if (command.contains(Platform.pathSeparator)) return File(command).existsSync();
  final sep = Platform.isWindows ? ';' : ':';
  final names = Platform.isWindows ? [command, '$command.exe', '$command.cmd', '$command.bat'] : [command];
  for (final dir in ((await shellEnvironment())['PATH'] ?? '').split(sep)) {
    if (dir.isNotEmpty && names.any((n) => File('$dir${Platform.pathSeparator}$n').existsSync())) return true;
  }
  return false;
}

/// One lookup shared by every caller: at startup all providers ask at once,
/// and a shell each ran past the timeout.
Future<Map<String, String>> shellEnvironment() => _cached ??= _read();

Future<Map<String, String>> _read() async {
  final env = Map<String, String>.of(Platform.environment)..removeWhere((k, _) => _claudeSession.contains(k));
  if (!Platform.isWindows) {
    final shell = env['SHELL'] ?? '/bin/zsh';
    try {
      // Interactive too (-i): PATH is often set in .zshrc, which a login
      // shell alone skips. Markers keep anything .zshrc prints out of it.
      // printenv: an unset variable must not stop a shell with nounset on,
      // and fish rejects `${X-}`.
      final r = await Process.run(shell, [
        '-ilc',
        'printf "<<PATH>>%s<<PATH>><<CCD>>%s<<CCD>>" "\$PATH" "\$(printenv CLAUDE_CONFIG_DIR)"',
      ]).timeout(const Duration(seconds: 20));
      final out = r.stdout as String;
      final path = RegExp('<<PATH>>(.*)<<PATH>>').firstMatch(out)?.group(1) ?? '';
      if (path.isEmpty) throw StateError('no PATH');
      env['PATH'] = path;
      // Claude Code's config folder, often set in .zshrc: the claude Deck starts must use your account.
      final ccd = RegExp('<<CCD>>(.*)<<CCD>>').firstMatch(out)?.group(1) ?? '';
      if (ccd.isNotEmpty) env['CLAUDE_CONFIG_DIR'] = ccd;
    } catch (_) {
      // Keep the inherited PATH for now, and ask the shell again next time.
      _cached = null;
    }
    // A cold shell right after a reboot can miss the timeout. Where claude,
    // glab and gh install stays on PATH even then.
    final home = env['HOME'] ?? '';
    final dirs = (env['PATH'] ?? '/usr/bin:/bin').split(':');
    for (final d in ['$home/.local/bin', '/opt/homebrew/bin', '/usr/local/bin']) {
      if (!dirs.contains(d) && Directory(d).existsSync()) dirs.add(d);
    }
    env['PATH'] = dirs.join(':');
    _setOwnPath(env['PATH']!);
  }
  return env;
}

/// Dart finds a bare command (`glab`, `claude`) on Deck's own PATH, not on
/// the `environment:` a call passes. Started from the Dock, that PATH is
/// `/usr/bin:/bin`: set the shell's on the process, so every call finds them.
void _setOwnPath(String path) {
  try {
    final setenv = DynamicLibrary.process()
        .lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, Pointer<Utf8>, int)>('setenv');
    using((arena) => setenv('PATH'.toNativeUtf8(allocator: arena), path.toNativeUtf8(allocator: arena), 1));
  } catch (_) {}
}

/// Runs [run] with [body] written as JSON to a file of its own, removed after.
/// Free text (a ticket title, a message) goes to `glab api` and `gh api` this
/// way, through `--input`, never on the command line, where a shell (Windows
/// runs them through one) could read it as code.
Future<T> withJsonFile<T>(Object body, Future<T> Function(String path) run) async {
  final dir = await Directory.systemTemp.createTemp('deck-');
  try {
    final f = File('${dir.path}${Platform.pathSeparator}body.json');
    await f.writeAsString(jsonEncode(body));
    return await run(f.path);
  } finally {
    await dir.delete(recursive: true);
  }
}
