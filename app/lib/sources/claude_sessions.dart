// Your Claude Code sessions, read from their transcripts in
// <CLAUDE_CONFIG_DIR or ~/.claude>/projects/<folder>/<session id>.jsonl. 0 tokens: Claude Code already
// writes a title for each session (ai-title), Deck only reads.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../core/models/activity.dart';
import '../core/models/config.dart';
import '../core/models/session_progress.dart';
import '../data/deck_home.dart';
import 'shell_env.dart';

/// The folder of the `claude` Deck starts, so sessions are read where they are written.
Future<String> _claudeDir() async => (await shellEnvironment())['CLAUDE_CONFIG_DIR'] ?? p.join(userHome, '.claude');

/// Claude Code writes `sessions/<pid>.json` for each running session and
/// deletes it on exit, so no file means the session was closed.
bool sessionOpen(String id, {required String dir}) {
  final d = Directory(dir);
  if (!d.existsSync()) return false;
  for (final f in d.listSync().whereType<File>()) {
    if (!f.path.endsWith('.json')) continue;
    try {
      if ((jsonDecode(f.readAsStringSync()) as Map)['sessionId'] == id) return true;
    } catch (_) {
      // Being written: next poll.
    }
  }
  return false;
}

/// One session on one day.
class SessionDay {
  const SessionDay({required this.id, required this.title, required this.cwd, required this.start, required this.end, required this.prompts});

  final String id;
  final String title;
  final String cwd;
  final DateTime start;
  final DateTime end;

  /// Messages you typed that day.
  final int prompts;
}

Map<String, Object?>? _entry(String line) {
  try {
    final e = jsonDecode(line);
    return e is Map<String, Object?> ? e : null;
  } on FormatException {
    return null;
  }
}

String? _prompt(Map<String, Object?> e) {
  if (e['type'] != 'user' || e['isMeta'] == true) return null;
  final origin = e['origin'];
  final content = (e['message'] as Map?)?['content'];
  if (origin is Map && origin['kind'] != 'human') return null;
  return content is String && !content.startsWith('<') ? content : null;
}

/// The days of one transcript, for interactive sessions only (not `claude -p`).
List<SessionDay> parseSessionDays(String id, Iterable<String> lines) {
  String? title, cwd, first;
  final days = <String, (DateTime, DateTime, int)>{};
  for (final line in lines) {
    final e = _entry(line);
    if (e == null) continue;
    if (e['entrypoint'] is String && e['entrypoint'] != 'cli') return const [];
    if (e['type'] == 'ai-title') title = e['aiTitle'] as String?;
    cwd ??= e['cwd'] as String?;
    final at = DateTime.tryParse('${e['timestamp']}')?.toLocal();
    if (at == null) continue;
    final prompt = _prompt(e);
    first ??= prompt;
    final key = at.toIso8601String().substring(0, 10);
    final (s, end, n) = days[key] ?? (at, at, 0);
    days[key] = (at.isBefore(s) ? at : s, at.isAfter(end) ? at : end, n + (prompt == null ? 0 : 1));
  }
  final name = title ?? first?.split('\n').first;
  if (name == null || cwd == null) return const [];
  return [
    for (final d in days.values)
      if (d.$3 > 0) SessionDay(id: id, title: name.length > 90 ? '${name.substring(0, 89)}…' : name, cwd: cwd, start: d.$1, end: d.$2, prompts: d.$3),
  ];
}

/// Where a session is now, from the end of its transcript.
SessionProgress? parseProgress(Iterable<String> lines, DateTime modified, DateTime now, {bool open = true}) {
  String? title, last, stop, cwd;
  for (final line in lines) {
    final e = _entry(line);
    if (e == null) continue;
    cwd = e['cwd'] as String? ?? cwd;
    if (e['type'] == 'ai-title') title = e['aiTitle'] as String?;
    if (_prompt(e) != null) stop = null;
    if (e['type'] == 'assistant') {
      final m = e['message'] as Map;
      stop = m['stop_reason'] as String? ?? stop;
      for (final c in (m['content'] as List? ?? const [])) {
        final text = (c as Map)['text'];
        if (c['type'] == 'text' && text is String && text.trim().isNotEmpty) last = text.trim().split('\n').first;
      }
    }
  }
  if (title == null && last == null) return null;
  final status = !open
      ? SessionStatus.closed
      : stop == 'end_turn'
      ? SessionStatus.done
      : now.difference(modified).inMinutes < 3
      ? SessionStatus.working
      : SessionStatus.idle;
  return SessionProgress(status: status, title: title, last: last, cwd: cwd, at: modified);
}

/// The transcript of session [id] in Claude Code folder [claudeDir].
File? transcriptOf(String id, String claudeDir) {
  final dir = Directory(p.join(claudeDir, 'projects'));
  if (!dir.existsSync()) return null;
  for (final d in dir.listSync().whereType<Directory>()) {
    final f = File(p.join(d.path, '$id.jsonl'));
    if (f.existsSync()) return f;
  }
  return null;
}

/// Where session [id] is now, from the last 256 KB of its transcript [f].
Future<SessionProgress?> readProgress(File f, String id, DateTime now, String claudeDir) async {
  final open = sessionOpen(id, dir: p.join(claudeDir, 'sessions'));
  final raf = await f.open();
  try {
    final len = await raf.length();
    await raf.setPosition(len > 262144 ? len - 262144 : 0);
    final lines = utf8.decode(await raf.read(262144), allowMalformed: true).split('\n');
    return parseProgress(len > 262144 ? lines.skip(1) : lines, await f.lastModified(), now, open: open);
  } finally {
    await raf.close();
  }
}

/// Polls session [id] every 5 seconds while a card shows it. Null until
/// Claude Code writes the transcript.
Stream<SessionProgress?> watchProgress(String id) async* {
  // Once per stream: while the shell fails, each lookup starts a new one.
  final dir = await _claudeDir();
  File? f; // Found once: finding it lists every Claude project folder.
  while (true) {
    f ??= transcriptOf(id, dir);
    if (f != null && !f.existsSync()) f = null;
    yield f == null ? null : await readProgress(f, id, DateTime.now(), dir);
    await Future<void>.delayed(const Duration(seconds: 5));
  }
}

/// Session days from transcripts changed since [since]. Runs off the UI thread.
Future<List<SessionDay>> recentSessionDays(DateTime since) async {
  final root = p.join(await _claudeDir(), 'projects');
  return Isolate.run(() {
    final dir = Directory(root);
    if (!dir.existsSync()) return <SessionDay>[];
    final out = <SessionDay>[];
    // Only <folder>/<session id>.jsonl: subagent transcripts sit deeper.
    for (final f in dir.listSync().whereType<Directory>().expand((d) => d.listSync().whereType<File>())) {
      if (!f.path.endsWith('.jsonl') || f.lastModifiedSync().isBefore(since)) continue;
      try {
        out.addAll(parseSessionDays(p.basenameWithoutExtension(f.path), f.readAsLinesSync()));
      } catch (_) {
        // A transcript being written or unreadable: next time.
      }
    }
    return out;
  });
}

String _hm(DateTime d) => d.toIso8601String().substring(11, 16);

/// The log line of a session day, named after the project whose folder holds it.
Activity sessionActivity(SessionDay s, List<ProjectConfig> projects) {
  bool holds(String? dir) => dir != null && dir.isNotEmpty && (expandHome(dir) == s.cwd || p.isWithin(expandHome(dir), s.cwd));
  final project = projects.where((x) => holds(x.dir)).firstOrNull;
  return Activity(
    at: s.start,
    kind: 'session',
    title: s.title,
    id: 'session:${s.id}:${s.start.toIso8601String().substring(0, 10)}',
    source: 'claude',
    project: project?.name ?? p.basename(s.cwd),
    detail: '${_hm(s.start)}–${_hm(s.end)}, ${s.prompts} ${s.prompts == 1 ? 'prompt' : 'prompts'}',
  );
}
