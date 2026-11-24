// The board: snapshots per provider, your triage, background runs. Owns the
// fetch cycle: direct sources run here, the rest go to background Claude
// sessions, one per task, which answer through the Deck MCP server.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../claude/tasks.dart';
import '../claude/worker.dart';
import '../core/activity_log.dart';
import '../core/auto_close.dart';
import '../core/classify/gitlab.dart';
import '../core/classify/jira.dart';
import '../core/classify/message.dart';
import '../core/classify/notes.dart';
import '../core/classify/time.dart';
import '../core/classify/todo.dart';
import '../core/links.dart';
import '../core/models/activity.dart';
import '../core/models/card.dart';
import '../core/models/claude_run.dart';
import '../core/models/config.dart';
import '../core/models/overview.dart';
import '../core/models/records.dart';
import '../core/models/snapshot.dart';
import '../core/projects.dart';
import '../core/providers_catalog.dart';
import '../core/tickets.dart';
import '../core/tool_rules.dart';
import '../data/activity_store.dart';
import '../data/permission_log.dart';
import '../data/git_backup.dart';
import '../data/run_log.dart';
import '../data/stores.dart';
import 'project_overview.dart';
import '../mcp/deck_server.dart';
import '../sources/claude_sessions.dart';
import '../sources/github_source.dart';
import '../sources/gitlab_source.dart';
import 'forges.dart';
import 'notices.dart';
import 'reviews.dart';
import 'settings.dart';

part 'board.freezed.dart';
part 'board.g.dart';

const mcpPort = 4777;

final gitBackupProvider = Provider((ref) => GitBackup(ref.watch(homeProvider)));

/// A background session asks to use a tool it was not given.
class PermissionAsk {
  PermissionAsk(this.tool, this.input);

  final String tool;
  final Map<String, Object?> input;
  final answer = Completer<bool>();

  /// Set when you chose Always allow: the rule saved with the answer.
  String? rule;
}

@freezed
abstract class BoardState with _$BoardState {
  const factory BoardState({
    @Default({}) Map<String, Snapshot> snapshots,
    @Default({}) Map<String, Triage> triage,

    /// Links you made (true) or cut (false), per pair key (core/links.dart).
    @Default({}) Map<String, bool> links,

    /// Provider ids and card keys being fetched.
    @Default({}) Set<String> busy,
    @Default([]) List<ClaudeRun> runs,
    @Default([]) List<PermissionAsk> asks,
  }) = _BoardState;
}

@Riverpod(keepAlive: true)
class Board extends _$Board implements DeckBackend {
  GitlabSource get _gitlab => ref.read(gitlabSourceProvider);
  GithubSource get _github => ref.read(githubSourceProvider);
  final _tasks = <String, TaskSpec>{};

  /// Task id → the background run that does it.
  final _runOf = <String, String>{};

  /// Task id → the error Claude submitted for it, so its run shows failed.
  final _taskErrors = <String, String>{};
  final _archives = <String, ({DeckCard card, Completer<String> done})>{};

  /// Jira ticket runs waiting for Claude's answer: the key and link.
  final _tickets = <String, Completer<({String ref, String url})?>>{};

  /// Runs that act once and feed no board column: no snapshot to fail.
  static const _actRuns = {archiveProvider, inboxProvider, ticketProvider};

  /// Review MRs you had approved at the last GitLab fetch. Null until the first one.
  Set<String>? _approved;

  SnapshotStore get _snaps => SnapshotStore(ref.read(homeProvider));
  TriageStore get _triage => TriageStore(ref.read(homeProvider));
  LinkStore get _links => LinkStore(ref.read(homeProvider));
  ActivityStore get _activity => ActivityStore(ref.read(homeProvider));

  Future<void> _log(Iterable<Activity> items) async {
    if (items.isEmpty) return;
    if ((await _activity.add(items)).isNotEmpty) await _backup();
  }

  DeckCard? _card(String key) {
    for (final s in _s.snapshots.values) {
      for (final c in s.cards) {
        if (c.key == key) return c;
      }
    }
    return null;
  }

  /// Logs each of [keys] as done, now.
  Future<void> _logDone(Iterable<String> keys, {String? reason}) async {
    final cfg = await ref.read(settingsProvider.future);
    final now = DateTime.now();
    await _log([for (final k in keys) ?_card(k)].map((c) => cardActivity(c, 'done', cfg.projects, now, detail: reason)));
  }

  @override
  Future<BoardState> build() async {
    final cfg = await ref.watch(settingsProvider.future);
    final snaps = <String, Snapshot>{
      for (final id in cfg.providers.keys) id: await _snaps.load(id),
      'todo': await _snaps.load('todo'),
      'issues': await _snaps.load('issues'),
    };
    // Settings changes rebuild the board; keep the run history and open asks.
    final prev = state.value;
    return BoardState(snapshots: snaps, triage: await _triage.load(), links: await _links.load(), runs: prev?.runs ?? const [], asks: prev?.asks ?? const []);
  }

  BoardState get _s => state.requireValue;
  void _set(BoardState s) => state = AsyncData(s);

  Future<void> _save(String provider, Snapshot s) async {
    _set(_s.copyWith(snapshots: {..._s.snapshots, provider: s}));
    await _snaps.save(provider, s);
    if (provider == 'todo') await _backup();
  }

  Future<void> _backup() async {
    final cfg = await ref.read(settingsProvider.future);
    if (cfg.gitBackup) unawaited(ref.read(gitBackupProvider).run());
  }

  Future<void> _fail(String provider, Object e) async {
    final old = _s.snapshots[provider] ?? const Snapshot();
    await _save(provider, old.copyWith(state: SourceState.error, message: '$e'.replaceFirst(RegExp(r'^\w+Error: '), '')));
  }

  void _busy(String id, bool on) => _set(_s.copyWith(busy: on ? {..._s.busy, id} : ({..._s.busy}..remove(id))));

  /// Fetches every enabled provider: direct ones here, the rest in background
  /// Claude runs, one per task and all at once, so a slow one holds no other.
  Future<void> refresh() async {
    final cfg = await ref.read(settingsProvider.future);
    final now = DateTime.now();
    unawaited(_logSessions(cfg, now));
    final viaClaude = <TaskSpec>[];
    for (final e in cfg.providers.entries.where((e) => e.value.enabled)) {
      if (await _noScope(e.key, e.value, cfg)) continue;
      if (e.key == 'gitlab' && e.value.access == Access.cli) {
        unawaited(_refreshGitlab());
      } else if (e.key == 'github' && e.value.access == Access.cli) {
        unawaited(_refreshGithub());
      } else if (!_s.busy.contains(e.key)) {
        final spec = taskFor(e.key, e.value, _s.snapshots[e.key]?.at, now, open: _openAsks(e.key), projects: cfg.projects, cards: _noteTargets(), atlassian: cfg.providers['jira']?.options['connector']);
        if (spec != null) viaClaude.add(spec);
        if (e.key == 'mail') viaClaude.addAll([..._notesTask(e.value, now), ?inboxTask(_inboxSenders(), now)]);
      }
    }
    unawaited(_refreshIssues(cfg));
    unawaited(ref.read(reviewsProvider.notifier).cleanClosed());
    await Future.wait([
      for (final s in viaClaude) _runClaude([s], cfg),
    ]);
  }

  /// Fetches one provider alone: Fetch Now in its settings, or the calendar
  /// before an alarm.
  Future<void> refreshOne(String provider) async {
    final cfg = await ref.read(settingsProvider.future);
    final p = cfg.providers[provider];
    if (p == null || !p.enabled || await _noScope(provider, p, cfg)) return;
    if (provider == 'gitlab' && p.access == Access.cli) return _refreshGitlab();
    if (provider == 'github' && p.access == Access.cli) return _refreshGithub();
    if (_s.busy.contains(provider)) return;
    final now = DateTime.now();
    final spec = taskFor(provider, p, _s.snapshots[provider]?.at, now, open: _openAsks(provider), projects: cfg.projects, cards: _noteTargets(), atlassian: cfg.providers['jira']?.options['connector']);
    if (spec == null) return;
    await Future.wait([
      for (final s in [
        spec,
        if (provider == 'mail') ...[..._notesTask(p, now), ?inboxTask(_inboxSenders(), now)],
      ])
        _runClaude([s], cfg),
    ]);
  }

  /// A provider kept to the projects set up in Deck, when none has a repo or
  /// board there: no run, an empty column that says why.
  Future<bool> _noScope(String provider, ProviderConfig p, DeckConfig cfg) async {
    if (projectScope(provider, p, cfg.projects)?.isEmpty != true) return false;
    final where = provider == 'jira' ? 'a Jira task board' : 'a ${providerInfo(provider).name} repo or task board';
    await _save(provider, Snapshot(state: SourceState.ok, message: 'No project has $where', at: DateTime.now()));
    return true;
  }

  /// Meeting notes ride along with Mail when it has the user's name: same
  /// Gmail tools, but a task of its own, since notes skip the inbox.
  List<TaskSpec> _notesTask(ProviderConfig mail, DateTime now) {
    if ((mail.options['notesName'] ?? '').trim().isEmpty || _s.busy.contains('notes')) return const [];
    return [?taskFor('notes', mail, _s.snapshots['notes']?.at, now, cards: _noteTargets())];
  }

  /// The open merge requests, issues and todos a meeting step may be about.
  List<NoteTarget> _noteTargets() => [
    for (final p in const ['gitlab', 'github', 'jira', 'issues', 'todo'])
      for (final c in _s.snapshots[p]?.cards ?? const <DeckCard>[])
        if (!(_s.triage[c.key]?.done ?? false)) (key: c.key, ref: p == 'todo' ? '' : c.ref, title: c.title),
  ];

  /// Issues assigned to you on the projects' GitLab and GitHub task boards.
  Future<void> _refreshIssues(DeckConfig cfg) async {
    List<String> boards(String provider) => [
      for (final p in cfg.projects)
        if (p.board?.startsWith('$provider:') ?? false) p.board!.substring(provider.length + 1),
    ];
    final gitlab = boards('gitlab'), github = boards('github');
    if (_s.busy.contains('issues') || (gitlab.isEmpty && github.isEmpty)) return;
    _busy('issues', true);
    try {
      final now = DateTime.now();
      final r = await Future.wait([
        gitlab.isEmpty ? Future.value(<IssueRecord>[]) : _gitlab.fetchIssues(gitlab),
        github.isEmpty ? Future.value(<IssueRecord>[]) : fetchGithubIssues(github),
      ]);
      final cards = [for (final i in r[0]) classifyIssue(i, now, provider: 'gitlab'), for (final i in r[1]) classifyIssue(i, now, provider: 'github')];
      await _save('issues', Snapshot(state: SourceState.ok, message: '${cards.length} open', at: now, cards: cards));
    } catch (e) {
      await _fail('issues', e);
    } finally {
      _busy('issues', false);
    }
  }

  /// Claude Code sessions of the last two days, once idle for 30 minutes, so
  /// a session is logged with its whole day.
  Future<void> _logSessions(DeckConfig cfg, DateTime now) async {
    try {
      final days = await recentSessionDays(now.subtract(const Duration(days: 2)));
      // A session started from a card says which one.
      final cards = {
        for (final e in _s.triage.entries)
          if (e.value.session != null) e.value.session!: _card(e.key),
      };
      await _log([
        for (final d in days)
          if (now.difference(d.end).inMinutes >= 30)
            if (cards[d.id] case final c?) sessionActivity(d, cfg.projects).copyWith(ref: c.ref, url: c.url) else sessionActivity(d, cfg.projects),
      ]);
    } catch (_) {
      // No transcripts folder or unreadable: nothing to log.
    }
  }

  /// Message ids of the asks still open on the board, newest first, at most 20.
  List<String> _openAsks(String provider) {
    final cards = [
      for (final c in _s.snapshots[provider]?.cards ?? const <DeckCard>[])
        if (c.kind != 'noise' && !(_s.triage[c.key]?.done ?? false)) c,
    ]..sort((a, b) => (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)));
    return [for (final c in cards.take(20)) c.key.substring(provider.length + 1)];
  }

  /// Senders of the open FYI and noise mail cards: the inbox listing checks
  /// whether their mail is still in the inbox.
  List<String> _inboxSenders() => [
    for (final c in _s.snapshots['mail']?.cards ?? const <DeckCard>[])
      if (!(_s.triage[c.key]?.done ?? false)) ?inboxSender(c),
  ];

  Future<void> _close(Iterable<String> keys, String reason) async {
    final all = closeCards(_s.triage, keys, reason, at: DateTime.now());
    final closed = [
      for (final k in keys)
        if (all[k] != _s.triage[k]) k,
    ];
    if (closed.isEmpty) return;
    _set(_s.copyWith(triage: all));
    await _triage.save(all);
    await _backup();
    await _logDone(closed, reason: reason);
  }

  /// Todos that point at a merge request are done once it is merged.
  Future<void> _closeMergedTodos(GitlabSource src) async {
    final merged = <String>[];
    for (final (c, path, iid) in openMrTodos(_s.snapshots['todo'] ?? const Snapshot(), _s.triage)) {
      try {
        if (await src.mergedAt(path, iid) != null) merged.add(c.key);
      } catch (_) {
        // Not found or no access: leave the todo open.
      }
    }
    if (merged.isNotEmpty) await _close(merged, 'MR merged');
  }

  /// Your MRs that left the open list and were merged, and new approvals you gave.
  Future<void> _logGitlab(GitlabSource src, Iterable<DeckCard> gone, MrFetch f, DateTime now) async {
    final cfg = await ref.read(settingsProvider.future);
    final lines = newApprovals(f.records, f.me, _approved, now);
    _approved = approvedBy(f.records, f.me);
    for (final c in gone) {
      try {
        if (await src.mergedAt(c.path!, c.iid!) case final at?) lines.add(cardActivity(c, 'merged', cfg.projects, at));
      } catch (_) {
        // Not found or no access: nothing to log.
      }
    }
    await _log(lines);
  }

  Future<void> _refreshGithub() async {
    if (_s.busy.contains('github')) return;
    _busy('github', true);
    try {
      final cfg = await ref.read(settingsProvider.future);
      final f = await _github.fetchAll(only: projectScope('github', cfg.providers['github'] ?? const ProviderConfig(), cfg.projects));
      final now = DateTime.now();
      final cards = [for (final m in f.records) classifyMr(m, f.me, now, provider: 'github')];
      await _save('github', Snapshot(state: SourceState.ok, message: '${cards.length} open', at: now, me: f.me, cards: cards));
    } catch (e) {
      await _fail('github', e);
    } finally {
      _busy('github', false);
    }
  }

  Future<void> _refreshGitlab() async {
    if (_s.busy.contains('gitlab')) return;
    _busy('gitlab', true);
    try {
      final cfg = await ref.read(settingsProvider.future);
      final f = await _gitlab.fetchAll(only: projectScope('gitlab', cfg.providers['gitlab'] ?? const ProviderConfig(), cfg.projects));
      final now = DateTime.now();
      final cards = [for (final m in f.records) classifyMr(m, f.me, now)];
      final gone = (_s.snapshots['gitlab']?.cards ?? const <DeckCard>[]).where((c) => c.lane == Lane.mine && !cards.any((n) => n.key == c.key));
      await _logGitlab(_gitlab, gone, f, now);
      await _save('gitlab', Snapshot(state: SourceState.ok, message: '${cards.length} open', at: now, me: f.me, cards: cards));
      await _closeMergedTodos(_gitlab);
    } catch (e) {
      await _fail('gitlab', e);
    } finally {
      _busy('gitlab', false);
    }
  }

  double get spentToday {
    final d = DateTime.now();
    return _s.runs.where((r) => r.at.year == d.year && r.at.month == d.month && r.at.day == d.day).fold(0, (a, r) => a + r.costUsd);
  }

  /// Makes a ticket for [c] on its project's board with the [title] and
  /// [body] you checked, then closes [c]: the ticket card takes its place.
  /// Returns a line for a toast.
  Future<String> makeTicket(DeckCard c, String title, String body) async {
    final cfg = await ref.read(settingsProvider.future);
    final board = ticketBoard(c, cfg.projects);
    if (board == null) return 'This card\'s project has no task board. Set one in Settings › Projects.';
    _busy(c.key, true);
    try {
      final ({String ref, String url})? made;
      switch (board.provider) {
        case 'gitlab':
          made = await _gitlab.createIssue(board.target, title, body);
        case 'github':
          made = await createGithubIssue(board.target, title, body);
        default:
          if (spentToday >= cfg.claude.dailyBudgetUsd) return 'Daily Claude budget is spent.';
          final spec = ticketTask(board.target, title, body, DateTime.now(), atlassian: cfg.providers['jira']?.options['connector']);
          final done = Completer<({String ref, String url})?>();
          _tickets[spec.task.id] = done;
          await _runClaude([spec], cfg);
          // A run that never submitted leaves the completer waiting.
          made = _tickets.remove(spec.task.id) == null ? await done.future : null;
          if (made == null) return 'Could not make the ticket: ${_s.runs.lastOrNull?.error ?? 'Claude did not answer.'}';
      }
      final t = _s.triage[c.key] ?? const Triage();
      await setTriage(c.key, t.copyWith(note: [?t.note, 'Ticket ${made.ref}: ${made.url}'].join('\n')));
      await _close([c.key], 'Ticket ${made.ref}');
      unawaited(board.provider == 'jira' ? refreshOne('jira') : _refreshIssues(cfg));
      return 'Made ${made.ref}.';
    } catch (e) {
      return 'Could not make the ticket: $e';
    } finally {
      _busy(c.key, false);
    }
  }

  /// Archives the Gmail threads of [c] in a run of its own. Returns a line for a toast.
  Future<String> archive(DeckCard c) async {
    final cfg = await ref.read(settingsProvider.future);
    if (c.threads.isEmpty) return 'Nothing to archive.';
    if (spentToday >= cfg.claude.dailyBudgetUsd) return 'Daily Claude budget is spent.';
    final spec = archiveTask(c.threads, DateTime.now());
    final done = Completer<String>();
    _archives[spec.task.id] = (card: c, done: done);
    _busy(c.key, true);
    await _runClaude([spec], cfg);
    _busy(c.key, false);
    if (_archives.remove(spec.task.id) != null) done.complete('Could not archive: ${_s.runs.last.error ?? 'Claude did not answer.'}');
    return done.future;
  }

  /// GitLab, GitHub and Jira notification mail about a card already on the
  /// board is archived in the background, unless it asks something of you.
  /// Returns the rest.
  List<MessageRecord> _archiveTracked(List<MessageRecord> msgs, DateTime now) {
    final board = [
      for (final e in _s.snapshots.entries)
        if (e.key != 'mail') ...e.value.cards,
    ];
    bool tracked(MessageRecord m) => m.kind != 'ask' && m.about != null && onBoard(m.about!, board);
    final ids = [
      for (final m in msgs)
        if (tracked(m)) m.id,
    ];
    if (ids.isNotEmpty) {
      final n = plural(ids.length, 'notification');
      unawaited(
        archive(
          DeckCard(
            key: 'mail:tracked',
            provider: 'mail',
            lane: Lane.reply,
            ref: 'mail',
            url: '',
            title: '$n about cards already on the board',
            next: '',
            bucket: Bucket.clear,
            score: 0,
            kind: 'tracked',
            threads: ids,
          ),
        ),
      );
    }
    return [
      for (final m in msgs)
        if (!tracked(m)) m,
    ];
  }

  Future<void> _archived(String taskId, List<Map<String, Object?>> records, String? error) async {
    final a = _archives.remove(taskId);
    if (a == null) return;
    final c = a.card;
    final ok = {
      for (final r in records)
        if (r['ok'] == true) '${r['id']}',
    };
    final left = [
      for (final t in c.threads)
        if (!ok.contains(t)) t,
    ];
    if (error != null || ok.isEmpty) return a.done.complete('Could not archive: ${error ?? 'no thread archived.'}');
    final old = _s.snapshots['mail'] ?? const Snapshot();
    if (left.isNotEmpty) {
      await _save('mail', old.copyWith(cards: [for (final x in old.cards) x.key == c.key ? x.copyWith(threads: left) : x]));
      return a.done.complete('Archived ${ok.length}, ${left.length} failed.');
    }
    final n = plural(ok.length, 'mail');
    if (c.kind == 'noise' || c.kind == 'tracked') {
      // A sender group goes away: its next mail starts a fresh card.
      await _save(
        'mail',
        old.copyWith(
          cards: [
            for (final x in old.cards)
              if (x.key != c.key) x,
          ],
        ),
      );
      if (_s.triage.containsKey(c.key)) await setTriage(c.key, null);
      final cfg = await ref.read(settingsProvider.future);
      final now = DateTime.now();
      await _log([cardActivity(c.copyWith(key: '${c.key}@${now.millisecondsSinceEpoch}'), 'done', cfg.projects, now, detail: 'Archived $n')]);
    } else {
      await _close([c.key], 'Archived in Gmail');
    }
    a.done.complete('Archived $n.');
  }

  Future<void> _runClaude(List<TaskSpec> specs, DeckConfig cfg) async {
    final providers = [for (final s in specs) s.task.id.split('-').first];
    if (spentToday >= cfg.claude.dailyBudgetUsd) {
      for (final p in providers.where((p) => !_actRuns.contains(p))) {
        await _fail(p, 'Daily Claude budget of \$${cfg.claude.dailyBudgetUsd.toStringAsFixed(2)} is spent.');
      }
      return;
    }
    final runId = specs.first.task.id;
    for (final s in specs) {
      _tasks[s.task.id] = s;
      _runOf[s.task.id] = runId;
      _busy(providers[specs.indexOf(s)], true);
    }
    final run = await runClaude(
      specs: specs,
      run: runId,
      mcpPort: mcpPort,
      model: cfg.claude.model,
      home: ref.read(homeProvider),
      allowed: cfg.claude.allowedTools,
      // A run that ended well but whose tasks failed shows failed too.
      check: (run) async {
        final failed = <String>[];
        for (final s in specs) {
          final p = s.task.id.split('-').first;
          _runOf.remove(s.task.id);
          if (_taskErrors.remove(s.task.id) case final e?) failed.add(e);
          // A task Claude never submitted failed, with the run's error if any.
          if (_tasks.remove(s.task.id) != null) {
            failed.add('Claude did not send results.');
            if (!_actRuns.contains(p)) await _fail(p, run.error ?? failed.last);
          }
          _busy(p, false);
        }
        return failed.isEmpty ? null : failed.join(' ');
      },
    );
    if (run.error case final e?) {
      ref
          .read(noticesProvider.notifier)
          .add(NoticeKind.session, 'Background run failed', body: '${providers.join(', ')}: $e', route: '/settings?section=claude', error: true, toast: true);
    }
    _set(_s.copyWith(runs: [..._s.runs, run].length > 50 ? [..._s.runs.skip(1), run] : [..._s.runs, run]));
  }

  /// Fetches one card again.
  Future<void> reload(DeckCard c) async {
    final cfg = await ref.read(settingsProvider.future);
    final p = cfg.providers[c.provider];
    if (c.provider == 'gitlab' && c.lane != Lane.task && p?.access == Access.cli) {
      _busy(c.key, true);
      try {
        final role = c.lane == Lane.mine ? MrRole.mine : MrRole.review;
        final rec = await _gitlab.fetchOne(c.path!, c.iid!, role);
        final old = _s.snapshots['gitlab'] ?? const Snapshot();
        final cards = [
          for (final x in old.cards)
            if (x.key != c.key) x,
          if (rec != null) classifyMr(rec, old.me ?? await _gitlab.me(), DateTime.now()),
        ];
        await _save('gitlab', old.copyWith(cards: cards, message: '${cards.length} open'));
      } catch (e) {
        await _fail('gitlab', e);
      } finally {
        _busy(c.key, false);
      }
    } else {
      await refresh();
    }
  }

  Future<void> setTriage(String key, Triage? t) async {
    if ((t?.done ?? false) && !(_s.triage[key]?.done ?? false)) {
      unawaited(_logDone([key]));
      // Done ends Doing, and Flow lists it under Done today.
      t = t!.copyWith(doneAt: t.doneAt ?? DateTime.now(), startedAt: null);
    }
    final all = {..._s.triage};
    if (t == null || t == const Triage()) {
      all.remove(key);
    } else {
      all[key] = t;
    }
    _set(_s.copyWith(triage: all));
    await _triage.save(all);
    await _backup();
  }

  /// Links cards [a] and [b] ([on] true), cuts their link (false, so it is
  /// not found again), or forgets your choice (null).
  Future<void> setLink(String a, String b, bool? on) async {
    final all = {..._s.links};
    if (on == null) {
      all.remove(pairKey(a, b));
    } else {
      all[pairKey(a, b)] = on;
    }
    _set(_s.copyWith(links: all));
    await _links.save(all);
    await _backup();
  }

  // ---- DeckBackend: what Claude sessions reach through the Deck MCP ----

  @override
  List<DeckTask> pendingTasks(String? run) => [
    for (final s in _tasks.values)
      if (run != null && _runOf[s.task.id] == run) s.task,
  ];

  @override
  String? submit(String taskId, List<Map<String, Object?>> records, String? error) {
    if (_tasks[taskId] case final s? when taskId.startsWith('slack-')) records = withSlackUrls(records, s.task.input);
    // Refused records keep the task open, so Claude can send them again.
    final refused = error == null && _tasks.containsKey(taskId) ? recordProblems(taskId.split('-').first, records, _tasks[taskId]!.task.input) : null;
    if (refused == null && error != null && _tasks.containsKey(taskId)) _taskErrors[taskId] = error;
    if (refused == null) unawaited(_ingest(taskId, records, error));
    return refused;
  }

  Future<void> _ingest(String taskId, List<Map<String, Object?>> records, String? error) async {
    final spec = _tasks.remove(taskId);
    if (spec == null) return;
    final provider = taskId.split('-').first;
    if (provider == archiveProvider) return _archived(taskId, records, error);
    if (provider == ticketProvider) {
      final r = records.firstOrNull;
      _tickets.remove(taskId)?.complete(error != null || r == null || r['key'] == null ? null : (ref: '${r['key']}', url: '${r['url'] ?? ''}'));
      return;
    }
    if (provider == inboxProvider) {
      // A failed listing closes nothing: an empty list would close every card.
      if (error != null) return;
      final listedAt = DateTime.fromMillisecondsSinceEpoch(int.parse(taskId.split('-').last));
      return _close(leftInbox(_s.snapshots['mail']?.cards ?? const [], inboxBySender(spec.task.input, records), listedAt), 'Archived in Gmail');
    }
    if (error != null) return _fail(provider, error);
    final cfg = await ref.read(settingsProvider.future);
    final now = DateTime.now();
    final old = _s.snapshots[provider] ?? const Snapshot();
    // How far a mail run got, from the searches it lists beside the threads.
    final progress = provider == 'mail' ? mailProgress(spec.task.input, records, old.at, now) : null;
    if (progress != null) {
      records = [
        for (final r in records)
          if (!isSearchRecord(r)) r,
      ];
    }
    // Each record is read alone: one Claude got wrong is skipped, not the batch.
    var bad = 0;
    List<T> each<T>(T Function(Map<String, Object?>) read) {
      final ok = <T>[];
      for (final r in records) {
        try {
          ok.add(read(r));
        } catch (_) {
          bad++;
        }
      }
      return ok;
    }

    String skipped() => bad == 0 ? '' : ', ${plural(bad, 'record')} skipped (missing fields)';
    try {
      if (provider == 'calendar') {
        // The next 24 hours, fetched whole: replace.
        final events = each(EventRecord.fromJson)..sort((a, b) => a.start.compareTo(b.start));
        await _log(meetingsAttended(old.events, now));
        return await _save(provider, Snapshot(state: SourceState.ok, message: '${plural(events.length, 'meeting')}${skipped()}', at: now, events: events));
      }
      if (provider == 'notes') return await _notesTodos(records, cfg.providers['mail']?.options['notesName'] ?? '', now);
      final List<DeckCard> cards;
      switch (provider) {
        case 'jira':
          final esc = cfg.providers['jira']?.options['escalationType'] ?? 'Customer Escalation';
          cards = [for (final i in each(IssueRecord.fromJson)) classifyIssue(i, now, escalationType: esc)];
        case 'github':
          cards = [for (final m in each(MrRecord.fromJson)) classifyMr(m, old.me ?? '', now, provider: 'github')];
        default:
          // New messages since the last fetch, plus the open ones read again.
          // Search filters by day only: keep what came after the last check,
          // with 10 minutes of overlap for messages the search indexed late.
          final since = old.at?.subtract(const Duration(minutes: 10));
          var msgs = each(MessageRecord.fromJson);
          if (provider == 'mail') msgs = _archiveTracked(msgs, now);
          await _logUpdates(provider, msgs);
          msgs = await _foldTracked(provider, msgs, old.cards);
          final merged = mergeMessages(old.cards, msgs, provider, now, since: since);
          cards = merged.cards;
          await _close(merged.replied, 'You replied');
      }
      // With skipped records, keep the old check time: the next fetch reads
      // the same window again instead of losing them.
      await _save(
        provider,
        Snapshot(
          state: SourceState.ok,
          message:
              '${cards.length} open${skipped()}${progress == null || progress.cut.isEmpty ? '' : ', over 50 threads on ${progress.cut.join(', ')}: some were not read'}',
          at: bad == 0 ? progress?.at ?? now : old.at,
          me: old.me,
          cards: cards,
        ),
      );
    } catch (e) {
      await _fail(provider, 'Claude sent records Deck could not read: $e');
    }
  }

  /// Asks about a ticket or merge request already open go on its card as a
  /// note; a team report an existing ticket tracks makes no card. Returns the
  /// messages that still need a card of their own.
  Future<List<MessageRecord>> _foldTracked(String provider, List<MessageRecord> msgs, List<DeckCard> mine) async {
    final board = [
      for (final p in const ['gitlab', 'github', 'jira', 'issues'])
        for (final c in _s.snapshots[p]?.cards ?? const <DeckCard>[])
          if (!(_s.triage[c.key]?.done ?? false)) c,
    ];
    final f = foldTracked(msgs, board, {for (final c in mine) c.key}, provider);
    var triage = _s.triage;
    for (final e in f.notes.entries) {
      final t = triage[e.key] ?? const Triage();
      final lines = [
        for (final l in e.value)
          if (!(t.note ?? '').contains(l)) l,
      ];
      if (lines.isEmpty) continue;
      triage = {
        ...triage,
        e.key: t.copyWith(note: [?t.note, ...lines].join('\n')),
      };
    }
    if (triage != _s.triage) {
      _set(_s.copyWith(triage: triage));
      await _triage.save(triage);
      await _backup();
    }
    return f.keep;
  }

  /// Lasting news in messages goes to each project's Overview.
  Future<void> _logUpdates(String provider, List<MessageRecord> msgs) async {
    final byProject = <String, List<ProjectUpdate>>{};
    final docs = <String, List<ProjectDoc>>{};
    for (final m in msgs) {
      final p = m.project;
      if (p == null) continue;
      final source = provider == 'slack' ? m.where ?? m.from ?? 'Slack' : m.from ?? m.where ?? 'Mail';
      for (final d in m.docs) {
        // Only web links: the page opens them with a click.
        if (!d.url.startsWith('https://') || d.title.trim().isEmpty) continue;
        (docs[p] ??= []).add(ProjectDoc(url: d.url, title: d.title.trim(), provider: provider, source: source, at: m.at));
      }
      final text = m.lasting?.trim();
      if (text == null || text.isEmpty) continue;
      (byProject[p] ??= []).add(ProjectUpdate(id: '$provider:${m.id}', at: m.at, provider: provider, source: source, text: text, url: m.url));
    }
    final store = ref.read(overviewStoreProvider);
    for (final e in byProject.entries) {
      if (await store.add(e.key, e.value) > 0) {
        ref.invalidate(projectNewCountProvider(e.key));
        ref.invalidate(projectOverviewStateProvider(e.key));
      }
    }
    for (final e in docs.entries) {
      if (await store.addDocs(e.key, e.value) > 0) ref.invalidate(projectOverviewStateProvider(e.key));
    }
  }

  Future<ProjectConfig?> _projectNamed(String project) async {
    final cfg = await ref.read(settingsProvider.future);
    final q = project.trim().toLowerCase();
    return cfg.projects.where((p) => p.id == project || p.name.toLowerCase() == q || p.aliases.any((a) => a.toLowerCase() == q)).firstOrNull;
  }

  @override
  Future<bool> addProjectDoc(String project, String url, String title) async {
    final p = await _projectNamed(project);
    if (p == null) return false;
    // force: a link Claude was asked to add comes back even if you removed it.
    await ref.read(overviewStoreProvider).addDocs(p.id, [ProjectDoc(url: url, title: title, provider: 'claude', at: DateTime.now())], force: true);
    ref.invalidate(projectOverviewStateProvider(p.id));
    return true;
  }

  @override
  Future<bool> addProjectFact(String project, String section, String text, String? source) async {
    final p = await _projectNamed(project);
    if (p == null) return false;
    final store = ref.read(overviewStoreProvider);
    final o = await store.read(p.id);
    if (!o.facts.any((f) => f.section == section && f.text == text)) {
      // edited: the facts run keeps it as it is, like a line you wrote.
      await store.write(
        p.id,
        o.copyWith(
          facts: [
            ...o.facts,
            Fact(section: section, text: text, source: source, edited: true),
          ],
        ),
      );
      ref.invalidate(projectOverviewStateProvider(p.id));
    }
    return true;
  }

  @override
  Future<Map<String, Object?>?> projectOverview(String project) async {
    final p = await _projectNamed(project);
    if (p == null) return null;
    final store = ref.read(overviewStoreProvider);
    final since = DateTime.now().subtract(const Duration(days: 30));
    return {
      'project': p.name,
      'facts': [for (final f in (await store.read(p.id)).facts) f.toJson()..remove('edited')],
      'updates': [
        for (final u in await store.updates(p.id))
          if (u.at.isAfter(since)) {'day': u.at.toIso8601String().substring(0, 10), 'provider': u.provider, 'source': u.source, 'text': u.text, 'url': ?u.url},
      ],
      'documents': [
        for (final d in await store.docs(p.id))
          if (!d.removed) {'title': d.title, 'url': d.url, 'source': ?d.source},
      ],
    };
  }

  /// Next steps for you in meeting notes, added to the todos once each.
  Future<void> _notesTodos(List<Map<String, Object?>> records, String name, DateTime now) async {
    final todos = _s.snapshots['todo'] ?? const Snapshot(state: SourceState.ok);
    // Deleted steps keep their triage, so they are not added again.
    final have = {for (final c in todos.cards) c.key, ..._s.triage.keys};
    final added = <DeckCard>[];
    final targets = _noteTargets();
    var triage = _s.triage;
    var linked = 0;
    for (final r in records) {
      final steps = stepsFor('${r['steps'] ?? ''}', name);
      final links = stepLinks(r['links']);
      for (final (i, s) in steps.indexed) {
        final key = 'todo:notes:${r['id']}/$i';
        if (have.contains(key)) continue;
        // A step about an open card goes on it as a note: one card, which
        // closes with the merge request or issue.
        if (stepCard(s, targets, links) case final card?) {
          final t = triage[card] ?? const Triage();
          final line = 'From ${r['title']}: ${s.title}: ${s.need}';
          if (!(t.note ?? '').contains(line)) {
            triage = {...triage, card: t.copyWith(note: t.note == null ? line : '${t.note}\n$line')};
            linked++;
          }
          continue;
        }
        added.add(classifyTodo({'title': s.title, 'need': s.need, 'source': 'meeting', 'from': r['title'], 'url': r['url']}, now, key: key));
      }
    }
    if (linked > 0) {
      _set(_s.copyWith(triage: triage));
      await _triage.save(triage);
      await _backup();
    }
    if (added.isNotEmpty) {
      await _save('todo', todos.copyWith(state: SourceState.ok, at: now, cards: [...todos.cards, ...added]));
      final cfg = await ref.read(settingsProvider.future);
      await _log([for (final c in added) cardActivity(c, 'todo', cfg.projects, now)]);
    }
    await _save(
      'notes',
      Snapshot(
        state: SourceState.ok,
        message: '${plural(records.length, 'note')}, ${plural(added.length, 'new step')}${linked > 0 ? ', $linked on open cards' : ''}',
        at: now,
      ),
    );
  }

  /// Removes a todo. A meeting step keeps a done mark in triage, so the next
  /// notes fetch does not add it back.
  Future<void> deleteTodo(String key) async {
    final old = _s.snapshots['todo'] ?? const Snapshot(state: SourceState.ok);
    final all = {..._s.triage}..remove(key);
    if (key.startsWith('todo:notes:')) all[key] = Triage(done: true, doneReason: 'Deleted', doneAt: DateTime.now());
    _set(_s.copyWith(triage: all));
    await _triage.save(all);
    await _save(
      'todo',
      old.copyWith(
        cards: [
          for (final c in old.cards)
            if (c.key != key) c,
        ],
      ),
    );
  }

  @override
  void addTodo(Map<String, Object?> todo) {
    final old = _s.snapshots['todo'] ?? const Snapshot(state: SourceState.ok);
    final now = DateTime.now();
    final card = classifyTodo(todo, now);
    unawaited(_save('todo', old.copyWith(state: SourceState.ok, at: now, cards: [...old.cards, card])));
    unawaited(ref.read(settingsProvider.future).then((cfg) => _log([cardActivity(card, 'todo', cfg.projects, now)])));
  }

  @override
  Future<void> reportIssue(Map<String, Object?> issue) async {
    await RunLog(ref.read(homeProvider)).addIssue(issue);
    ref.read(noticesProvider.notifier).add(NoticeKind.session, 'A session reported an issue', body: '${issue['kind']}: ${issue['what']}');
  }

  @override
  Future<void> logActivity(Map<String, Object?> line) => _log([
    Activity(
      at: DateTime.now(),
      kind: 'note',
      title: '${line['title']}',
      source: 'claude',
      detail: line['detail'] as String?,
      project: line['project'] as String?,
      url: line['url'] as String?,
    ),
  ]);

  @override
  Future<List<Map<String, Object?>>> activity(DateTime from, DateTime to) async => [for (final e in await _activity.read(from, to)) e.toJson()];

  @override
  Future<bool> allowTool(String tool, Map<String, Object?> input) async {
    final cfg = await ref.read(settingsProvider.future);
    Future<void> log(String answer) =>
        ref.read(permissionLogProvider).add(PermissionEntry(at: DateTime.now(), tool: tool, input: input, answer: answer)).catchError((_) {});
    // A rule added while the session runs: it got its rules when it started.
    if (ruleAllows(cfg.claude.allowedTools, tool, input)) {
      await log('rule');
      return true;
    }
    if (!cfg.claude.askPermission) {
      await log('deny');
      return false;
    }
    final ask = PermissionAsk(tool, input);
    _set(_s.copyWith(asks: [..._s.asks, ask]));
    var timedOut = false;
    final ok = await ask.answer.future.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        timedOut = true;
        return false;
      },
    );
    _set(
      _s.copyWith(
        asks: [
          for (final a in _s.asks)
            if (a != ask) a,
        ],
      ),
    );
    final answer = timedOut ? 'timeout' : (ask.rule != null ? 'always' : (ok ? 'allow' : 'deny'));
    await log(answer);
    ref.invalidate(permissionHistoryProvider);
    ref
        .read(noticesProvider.notifier)
        .add(
          NoticeKind.permission,
          switch (answer) {
            'timeout' => 'No answer: $tool denied',
            'always' => 'Always allowed ${ask.rule}',
            'allow' => 'Allowed $tool once',
            _ => 'Denied $tool',
          },
          body: callSummary(tool, input),
          route: '/settings?section=claude',
          error: timedOut,
          toast: timedOut,
        );
    return ok;
  }
}
