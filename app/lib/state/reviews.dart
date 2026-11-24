// The reviews of each project: opening one for a merge request (fetch it, put
// its head on a local ref, keep the review), the session Claude runs to write
// the notes, chapters and pictures, and what the review page reads. Also what
// the review tools of the Deck MCP server reach.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../claude/review_task.dart';
import '../claude/tasks.dart' show atlassianTool;
import '../claude/worker.dart';
import '../core/models/config.dart';
import '../core/review/diff.dart';
import '../core/review/parse.dart';
import '../core/review/publish_plan.dart';
import '../core/review/review.dart';
import '../data/deck_home.dart';
import '../data/review_git.dart';
import '../data/review_store.dart';
import '../mcp/review_tools.dart';
import '../sources/mr_review.dart';
import '../sources/review_publish.dart';
import '../sources/review_pull.dart';
import '../sources/shell_env.dart';
import 'board.dart';
import 'notices.dart';
import 'project_info.dart';
import 'project_mrs.dart';
import 'session_run.dart';
import 'settings.dart';
import 'terminals.dart';

part 'reviews.g.dart';

typedef ReviewKey = ({String project, String id});

/// The reviews Deck holds for a project, newest first.
@riverpod
Future<List<Review>> projectReviews(Ref ref, String project) async {
  ref.watch(reviewsProvider);
  return ReviewStore(ref.watch(homeProvider)).list(project);
}

/// One review as stored: the MR and what the session wrote.
@riverpod
Future<Review?> review(Ref ref, ReviewKey key) async {
  ref.watch(reviewsProvider);
  return (await ref.read(reviewsProvider.notifier).reviewOf(key.project, key.id))?.review;
}

/// The diff of a review, derived from git at the head it is on now.
@riverpod
Future<DiffSnapshot> reviewDiff(Ref ref, ReviewKey key) async {
  final s = await ref.read(reviewsProvider.notifier).reviewOf(key.project, key.id);
  if (s == null) throw StateError('No review ${key.id}');
  return s.snapshot();
}

/// Where each thread's fix stands, read from git after every write.
@riverpod
Future<({Map<String, FixStatus> fixes, List<String> uncommitted})> reviewFixes(Ref ref, ReviewKey key) async {
  ref.watch(reviewsProvider);
  return ref.read(reviewsProvider.notifier).fixes(key);
}

/// The folder that has the review's branch checked out, where its fixes
/// go. Null: none yet, the first fix or Open in IDE makes a worktree.
@riverpod
Future<String?> reviewFolder(Ref ref, ReviewKey key) async {
  ref.watch(reviewsProvider);
  final s = await ref.read(reviewsProvider.notifier).reviewOf(key.project, key.id);
  return s == null ? null : checkoutOf(s.root, s.review.headRef).catchError((_) => null);
}

/// Whether the forge would merge it now.
@riverpod
Future<MrStatus?> reviewStatus(Ref ref, ReviewKey key) async {
  final r = await ref.watch(reviewProvider(key).future);
  return r?.mr == null ? null : fetchMrStatus(r!.mr!);
}

class ReviewsState {
  const ReviewsState({this.runs = const {}, this.changed = const {}});

  final Map<ReviewKey, SessionRun> runs;

  /// A counter per review, bumped on every write, so the page reads it again.
  final Map<ReviewKey, int> changed;
}

@Riverpod(keepAlive: true)
class Reviews extends _$Reviews implements ReviewBackend {
  final _services = <ReviewKey, ReviewService>{};
  final _stops = <ReviewKey, Completer<void>>{};

  @override
  ReviewsState build() {
    // A review's terminal session ended: the fixes accepted meanwhile go on
    // the branch.
    ref.listen(terminalsProvider, (before, now) {
      for (final tab in before?.tabs ?? const <TermTab>[]) {
        final k = tab.info.cardKey;
        if (k == null || !k.startsWith('review:') || before!.running(k) == null || now.running(k) != null) continue;
        final key = _services.keys.where((x) => terminalKey(x) == k).firstOrNull;
        if (key != null) unawaited(_applyQueued(key, _services[key]).then((_) => reviewChanged(key.project, key.id)));
      }
    });
    return const ReviewsState();
  }

  ReviewStore get _store => ReviewStore(ref.read(homeProvider));

  Future<String?> _dirOf(String project) async {
    final cfg = await ref.read(settingsProvider.future);
    final dir = cfg.projects.where((p) => p.id == project).firstOrNull?.dir;
    return dir == null ? null : expandHome(dir);
  }

  Future<ProjectConfig?> _projectOf(String project) async => (await ref.read(settingsProvider.future)).projects.where((p) => p.id == project).firstOrNull;

  @override
  Future<ReviewService?> reviewOf(String project, String id) async {
    final key = (project: project, id: id);
    final cached = _services[key];
    if (cached != null) return cached;
    final dir = await _dirOf(project);
    final r = _store.load(project, id);
    if (dir == null || r == null) return null;
    return _services[key] = ReviewService(_store, r, dir);
  }

  @override
  void reviewChanged(String project, String id) {
    final key = (project: project, id: id);
    state = ReviewsState(runs: state.runs, changed: {...state.changed, key: (state.changed[key] ?? 0) + 1});
    // A fix commit moves the head. Same shas give the cached snapshot back.
    ref.invalidate(reviewDiffProvider(key));
    if (state.runs[key]?.running ?? false) _count(key);
  }

  /// How far a running session is: a note on each visible file, then the
  /// chapters, the features and the triage.
  Future<void> _count(ReviewKey key) async {
    final s = await reviewOf(key.project, key.id);
    if (s == null) return;
    final snap = await s.snapshot();
    final r = s.review;
    final hidden = {...(r.hiddenTags ?? snap.hidden)};
    final visible = {
      for (final f in snap.files)
        if (!f.tags.any(hidden.contains)) f.path,
    };
    final done = {
      for (final n in r.fileNotes)
        if (visible.contains(n.path)) n.path,
      if (r.groups.isNotEmpty) ':groups',
      if (r.features.isNotEmpty) ':features',
      if (r.checklist.isNotEmpty) ':checklist',
      if (r.threads.any((t) => t.authorType == 'agent')) ':findings',
    };
    final run = state.runs[key];
    if (run == null || !run.running) return;
    _setRun(key, run.copyWith(total: visible.length + 4, done: done, countingSince: run.countingSince ?? run.startedAt));
  }

  /// Opens the review of merge request [iid] of [project], or the one Deck
  /// already holds, on the request's current head. Returns its id. [own]
  /// marks your own merge request; null keeps what the review says.
  Future<String> open(String project, int iid, {bool? own}) async {
    final cfg = await ref.read(settingsProvider.future);
    final p = cfg.projects.where((x) => x.id == project).firstOrNull;
    if (p?.dir == null || p?.repo == null) throw StateError('Set the folder and the repository of this project in Settings.');
    final dir = expandHome(p!.dir!);
    final mr = await fetchMr(p.repo!, iid);
    // A fix worktree on skim/mr-<iid> would block the fetch into it. Git
    // refuses to remove one with edits, and the error says so.
    await removeWorktree(dir, _worktreePath((project: project, id: '${mr.provider}-$iid')));
    final refs = await checkoutMr(dir, mr);
    final id = '${mr.provider}-$iid';
    final now = DateTime.now().toUtc().toIso8601String();
    final old = _store.load(project, id);
    final r = (old ?? Review(id: id, project: project, baseRef: refs.baseRef, headRef: refs.headRef, createdAt: now)).copyWith(
      mr: mr,
      baseRef: refs.baseRef,
      headRef: refs.headRef,
      local: refs.local,
      own: own ?? old?.own ?? false,
    );
    await _store.save(r);
    _services.remove((project: project, id: id));
    // A published review continues: the author's answers come in first. On
    // your own merge request the reviewers' threads are the point. A failed
    // pull leaves the review as it was.
    final s = await reviewOf(project, id);
    if (s != null && (s.lastPublishedRound != null || s.review.own))
      await pullDiscussions(s).catchError((_) => (threadsCreated: 0, threadsUpdated: 0, messagesAdded: 0, skipped: 0));
    reviewChanged(project, id);
    return id;
  }

  /// Opens the review of [branch] checked out in [folder] (the project
  /// folder or one of its worktrees), or the one Deck already holds. No
  /// merge request: the diff runs from origin's default branch to the
  /// working tree, so a Claude session's edits show before they are
  /// committed. When the branch has an open merge request, the review
  /// holds it, so fixes are pushed and answers sent with it. Returns its id.
  Future<String> openLocal(String project, String folder, String branch, {String? base}) async {
    final dir = await _dirOf(project);
    if (dir == null) throw StateError('Set the folder of this project in Settings.');
    final id = localReviewId(branch);
    final now = DateTime.now().toUtc().toIso8601String();
    final old = _store.load(project, id);
    final found = await _mrOfBranch(project, branch);
    final r = (old ?? Review(id: id, project: project, baseRef: base ?? await defaultBase(dir), headRef: branch, createdAt: now)).copyWith(
      headRef: branch,
      folder: folder,
      local: true,
      mr: found?.mr ?? old?.mr,
      own: old?.mr == null && found != null ? found.mine : old?.own ?? false,
    );
    await _store.save(r);
    _services.remove((project: project, id: id));
    reviewChanged(project, id);
    return id;
  }

  /// The open merge request whose source branch is [branch], and whether you
  /// wrote it. Null when there is none or the forge cannot be reached: the
  /// review then stays local only.
  Future<({MrSource mr, bool mine})?> _mrOfBranch(String project, String branch) async {
    try {
      final repo = (await _projectOf(project))?.repo;
      if (repo == null) return null;
      final m = (await ref.read(projectMrsProvider(project).future)).where((m) => m.branch == branch).firstOrNull;
      return m == null ? null : (mr: await fetchMr(repo, m.iid), mine: m.mine);
    } catch (_) {
      return null;
    }
  }

  /// Pushes the branch of the local review [key] to the same branch on
  /// origin: the accepted fixes go out without a merge request.
  Future<void> push(ReviewKey key) async {
    try {
      final s = await _service(key);
      if (_onBranch(key)) throw ReviewError('Claude is working on this review. Push when it is done.');
      await s.applyQueued();
      await s.pushFixes(await shellEnvironment());
    } finally {
      reviewChanged(key.project, key.id);
    }
  }

  /// The branches a local review of [project] may diff from, and the one it
  /// takes by default.
  Future<List<String>> projectBranches(String project) async =>
      branches(await _dirOf(project) ?? (throw StateError('Set the folder of this project in Settings.')));

  Future<String> defaultBaseOf(String project) async => defaultBase(await _dirOf(project) ?? (throw StateError('Set the folder of this project in Settings.')));

  /// The branches the local review [key] may diff from.
  Future<List<String>> baseChoices(ReviewKey key) async => branches((await _service(key)).root);

  /// Diffs the local review [key] from [base] from now on. Notes and threads
  /// stay as they are.
  Future<void> setBase(ReviewKey key, String base) async {
    if (state.runs[key]?.running ?? false) throw ReviewError('Claude is preparing this review on the current target. Stop it first, then change the target.');
    final s = await _service(key);
    await revParse(s.root, base);
    await _store.save(s.review.copyWith(baseRef: base, updatedAt: DateTime.now().toUtc().toIso8601String()));
    _services.remove(key);
    reviewChanged(key.project, key.id);
  }

  /// The id of the local review of [branch]: safe as a file name.
  static String localReviewId(String branch) => 'local-${branch.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-')}';

  /// Where the review's Claude runs: the reviewed checkout of a local
  /// review, else the project folder. Always the same per review, so its
  /// session resumes.
  static String _sessionDir(ReviewService? s, String dir) {
    final folder = s?.review.folder;
    return folder != null && Directory(folder).existsSync() ? folder : dir;
  }

  /// Deletes review [key]: its file in state, its fix worktree, and the
  /// `skim/mr-<iid>` branch Deck fetched (never your own branch). Git refuses
  /// a worktree with uncommitted edits: then the review stays, and the error
  /// says why.
  Future<void> delete(ReviewKey key) async {
    if (state.runs[key]?.running ?? false) throw ReviewError('Claude is working on this review. Stop it first.');
    if (inTerminal(key)) throw ReviewError('The Claude session of this review is open in a terminal. Close that tab first.');
    final r = _store.load(key.project, key.id);
    final dir = await _dirOf(key.project);
    if (dir != null && Directory(dir).existsSync()) {
      try {
        await removeWorktree(dir, _worktreePath(key));
        if (r != null && !r.local && r.headRef.startsWith('skim/')) await deleteBranch(dir, r.headRef);
      } on ProcessException catch (e) {
        throw ReviewError(e.message);
      }
    }
    await _store.delete(key.project, key.id);
    _services.remove(key);
    state = ReviewsState(runs: {...state.runs}..remove(key), changed: {...state.changed, key: (state.changed[key] ?? 0) + 1});
  }

  /// Deletes every review whose merge request was merged or closed on the
  /// forge. One that cannot go now (Claude works on it, a worktree with
  /// edits, the forge unreachable) is tried again on the next refresh.
  Future<void> cleanClosed() async {
    final cfg = await ref.read(settingsProvider.future);
    for (final pr in cfg.projects) {
      for (final r in _store.list(pr.id)) {
        if (r.mr == null) continue;
        try {
          final s = await fetchMrStatus(r.mr!);
          if (s.state == 'merged' || s.state == 'closed') await delete((project: pr.id, id: r.id));
        } catch (_) {
          // Kept for now: the next refresh tries again.
        }
      }
    }
  }

  /// Starts the session that writes the notes, chapters, pictures, ticket
  /// check, triage and findings of a review. One at a time per review. With
  /// [resume], it carries on a stopped one: the files that have a note are
  /// done. With [findings], only the findings run again.
  /// After a published round, it is the next round instead: only the code
  /// pushed since, one reply per open thread.
  Future<void> prepare(String project, String id, {bool resume = false, bool findings = false}) async {
    final svc = await reviewOf(project, id);
    final own = svc?.review.own ?? false;
    // Rounds are for reviewers: on your own merge request it is the analysis.
    final next = !findings && !resume && !own && svc?.lastPublishedRound != null;
    final skills = (await ref.read(settingsProvider.future)).claude.reviewSkills;
    final base = own ? analyzePrompt : reviewPrompt(skills);
    await _session(
      (project: project, id: id),
      kind: 'prepare',
      step: resume ? 'Resuming' : 'Starting',
      prompt: findings
          ? findingsPrompt(skills)
          : next
          ? roundPrompt(skills)
          : resume
          ? '$base\n\n$resumeNote'
          : base,
      // Only the hunt for issues runs skills: not the analysis of your own
      // merge request, not the answers to threads.
      skills: !own && skills.isNotEmpty,
    );
  }

  /// Starts the session that answers the threads waiting on Claude: talk,
  /// answers to post, and the fixes asked, committed locally.
  Future<void> answer(ReviewKey key) async {
    if (state.runs[key]?.running ?? false) return;
    final s = await reviewOf(key.project, key.id);
    if (s == null || !s.review.threads.any((t) => t.waiting)) return;
    var (fixDir, fixError) = await _fixTree(s, key);
    // A local review sees edits not committed yet: a fix commit would mix
    // with them, so no fix until they are committed.
    if (s.review.folder != null && fixDir != null && (await uncommittedFiles(fixDir).catchError((_) => const <String>[])).isNotEmpty) {
      (fixDir, fixError) = (null, '${s.review.headRef} has edits not committed yet. Commit them, then ask for the fix again.');
    }
    await _session(
      key,
      kind: 'answer',
      step: 'Reading the question',
      prompt: answerPrompt(
        own: s.review.own,
        fixDir: fixDir,
        branch: s.review.headRef,
        fixError: fixError,
        mr: switch (s.review.mr) {
          final m? => (provider: m.provider, iid: m.iid, path: m.projectPath),
          null => null,
        },
      ),
      edit: fixDir,
      extra: s.review.mr == null ? const {} : forgeEditTools(s.review.mr!),
    );
  }

  /// What a thread chat may change on the merge request when the user asks:
  /// its title and description, and comments already posted. Never a new
  /// comment: that goes out with Publish.
  static Set<String> forgeEditTools(MrSource mr) => switch (mr.provider) {
    'github' => {
      'Bash(gh pr edit ${mr.iid}:*)',
      'Bash(gh api --method PATCH repos/${mr.projectPath}/pulls/comments/:*)',
      'Bash(gh api --method PATCH repos/${mr.projectPath}/issues/comments/:*)',
    },
    _ => {'Bash(glab mr update ${mr.iid}:*)', 'Bash(glab api --method PUT projects/${Uri.encodeComponent(mr.projectPath)}/merge_requests/${mr.iid}/notes/:*)'},
  };

  /// On your own merge request: Claude writes the answer to every reviewer
  /// thread waiting on you, and commits a local fix where the change asked
  /// is clear. Nothing goes out until you publish.
  Future<void> feedback(ReviewKey key) async {
    if (state.runs[key]?.running ?? false) return;
    final s = await reviewOf(key.project, key.id);
    if (s == null || !s.review.threads.any((t) => t.answer == null && waitsOnYou(t, me: s.review.mr?.author ?? ''))) return;
    final (fixDir, fixError) = await _fixTree(s, key);
    await _session(
      key,
      kind: 'feedback',
      step: 'Reading the feedback',
      prompt: feedbackPrompt(fixDir: fixDir, branch: s.review.headRef, fixError: fixError),
      edit: fixDir,
    );
  }

  /// Feedback on your own merge request, then the analysis (notes, chapters,
  /// feature diagrams, ticket check) when the review has none yet. One
  /// session per review, so the two run one after the other.
  Future<void> feedbackThenAnalyze(ReviewKey key) async {
    await feedback(key);
    final r = (await reviewOf(key.project, key.id))?.review;
    if (r != null && r.fileNotes.isEmpty && r.groups.isEmpty) await prepare(key.project, key.id);
  }

  /// The working tree fixes are committed in, or why there is none.
  Future<(String?, String?)> _fixTree(ReviewService s, ReviewKey key) async {
    try {
      return (await worktreeFor(s.root, s.review.headRef, _worktreePath(key)), null);
    } catch (e) {
      return (null, '$e');
    }
  }

  String _worktreePath(ReviewKey key) => p.join(ref.read(homeProvider).cache.path, 'worktrees', key.project, key.id);

  /// The card key the review's terminal tab carries.
  static String terminalKey(ReviewKey key) => 'review:${key.project}/${key.id}';

  /// The review's Claude session is open in a terminal: Deck must not run it
  /// at the same time, or the two histories split.
  bool inTerminal(ReviewKey key) => ref.read(terminalsProvider).running(terminalKey(key)) != null;

  /// One Claude session per review: every run resumes the last one, so what
  /// it read is still in its context. In the project folder. [edit] is the
  /// only folder it may change, through Edit, Write and git add and commit.
  /// With [skills], it may run the review skills (Skill), which may start
  /// subagents (Agent). [extra] are more allowed tools.
  Future<void> _session(
    ReviewKey key, {
    required String kind,
    required String step,
    required String prompt,
    String? edit,
    bool skills = false,
    Set<String> extra = const {},
  }) async {
    if (state.runs[key]?.running ?? false) return;
    if (inTerminal(key)) return;
    final cfg = await ref.read(settingsProvider.future);
    final dir = await _dirOf(key.project);
    if (dir == null || !Directory(dir).existsSync()) return;
    final svc = await reviewOf(key.project, key.id);
    final resume = svc?.review.sessionId;
    final started = DateTime.now();
    _setRun(key, SessionRun(startedAt: started, step: step, kind: kind));
    final stop = _stops[key] = Completer<void>();
    final result = await runSession(
      home: ref.read(homeProvider),
      kind: 'review:$kind',
      subject: '${key.project}/${key.id}',
      // A session once opened in a terminal had every MCP server; resumed
      // here it gets a notice that they disconnected, and took Deck for one
      // of them.
      prompt: '$_deckToolsNote\n\n$prompt',
      providers: const ['review'],
      model: cfg.claude.codeModel,
      dir: _sessionDir(svc, dir),
      resume: resume,
      mcpUrl: _mcpUrl(key),
      // Tool search reaches the ticket connectors (Jira); files and git read the code.
      flags: [
        if (!skills) '--disable-slash-commands',
        '--tools',
        'Read,Grep,Glob,Bash,ToolSearch${edit == null ? '' : ',Edit,Write'}${skills ? ',Skill,Agent' : ''}',
        '--permission-mode',
        'auto',
      ],
      tools: {
        ..._tools(edit, cfg.providers['jira']?.options['connector']),
        if (skills) ...['Skill', 'Agent'],
        ...extra,
        ...cfg.claude.allowedTools,
      },
      timeout: const Duration(minutes: 30),
      stop: stop.future,
      onEvent: (ev) {
        final step = stepOf(ev);
        final run = state.runs[key];
        if (step != null && run != null && run.running) _setRun(key, run.copyWith(step: step));
      },
    );
    _stops.remove(key);
    final s = await reviewOf(key.project, key.id);
    if (result.sessionId case final sid?) await s?.setSessionId(sid);
    _setRun(key, state.runs[key]!.copyWith(step: result.error ?? 'Done', result: result));
    await _applyQueued(key, s);
    reviewChanged(key.project, key.id);
    if (result.error != 'Stopped.') {
      final what = s?.review.mr?.title ?? key.id;
      ref
          .read(noticesProvider.notifier)
          .add(
            NoticeKind.session,
            result.error != null
                ? 'Review session failed'
                : kind == 'answer'
                ? 'Claude answered in the review'
                : 'Review ready',
            body: result.error == null ? what : '$what: ${result.error}',
            route: '/project/${key.project}/review/${key.id}',
            error: result.error != null,
            toast: true,
          );
    }
    // A question asked while it ran: answer it now. One asked before and
    // left unanswered waits for the reviewer to ask again.
    if (result.error != 'Stopped.' && s != null && s.review.threads.any((t) => t.waiting && DateTime.parse(t.updatedAt).isAfter(started))) {
      unawaited(answer(key));
    }
  }

  static const _deckToolsNote =
      'The Deck MCP server is connected, whatever a notice says about other servers. '
      'When its tools (`mcp__deck__get_review`, `get_diff`, `add_thread`...) are deferred, load them with ToolSearch first.';

  String _mcpUrl(ReviewKey key) => 'http://127.0.0.1:$mcpPort/mcp?project=${Uri.encodeQueryComponent(key.project)}&review=${Uri.encodeQueryComponent(key.id)}';

  Set<String> _tools(String? edit, String? atlassian) => {
    'Read',
    'Grep',
    'Glob',
    ...gitTools(readOnlyGit),
    'Bash(glab issue view:*)',
    'Bash(gh issue view:*)',
    atlassianTool('getJiraIssue', atlassian),
    for (final t in reviewToolNames) 'mcp__deck__$t',
    if (edit != null) ...[
      // Permission paths: a leading // is an absolute path.
      'Edit(/$edit/**)',
      'Write(/$edit/**)',
      ...gitTools([...readOnlyGit, 'add', 'commit'], args: '-C $edit '),
    ],
  };

  /// Opens the review's Claude session in a Deck terminal, with the review
  /// tools, so you carry on the talk there. Deck runs nothing on this review
  /// while it is open.
  /// With [thread], the first message is about that thread.
  Future<void> openInTerminal(ReviewKey key, {Thread? thread}) async {
    if (state.runs[key]?.running ?? false) throw ReviewError('Claude is working on this review. Open it when it is done.');
    final s = await _service(key);
    final dir = await _dirOf(key.project);
    if (dir == null) throw ReviewError('Set the folder of this project in Settings.');
    final terms = ref.read(terminalsProvider.notifier);
    if (terms.focusRunning(terminalKey(key))) return;
    final (fixDir, _) = await _fixTree(s, key);
    final mcp = jsonEncode({
      'mcpServers': {
        'deck': {'type': 'http', 'url': _mcpUrl(key)},
      },
    });
    // The review's session when there is one, so what it read is still in
    // its context. Else a new one, kept as the review's session from now on.
    final id = s.review.sessionId;
    final fresh = id == null ? _newSessionId() : null;
    if (fresh != null) await s.setSessionId(fresh);
    final a = thread?.anchor;
    final first = thread != null
        ? threadTalkPrompt(thread.id, a == null ? null : '${a.path}:${a.line}', fresh: fresh != null)
        : (fresh != null ? talkPrompt : null);
    final atlassian = (await ref.read(settingsProvider.future)).providers['jira']?.options['connector'];
    List<String> flags() => ['--mcp-config', mcp, '--allowedTools', _tools(fixDir, atlassian).join(',')];
    final cmd = [
      'claude',
      if (id != null) ...['--resume', id] else ...['--session-id', fresh!],
      ...flags(),
      ?first,
    ].map(_q).join(' ');
    final pr = await _projectOf(key.project);
    await terms.open(
      TermInfo(
        title: s.review.mr == null ? key.id : '!${s.review.mr!.iid}',
        action: 'Claude',
        detail: s.review.mr?.title,
        cardKey: terminalKey(key),
        logo: pr == null ? null : logoFile(ref.read(homeProvider), pr),
        platforms: pr?.platforms ?? const [],
      ),
      cmd,
      _sessionDir(s, dir),
      restore: ['claude', '--resume', id ?? fresh!, ...flags()].map(_q).join(' '),
    );
    reviewChanged(key.project, key.id);
  }

  /// A random UUID v4, the form claude --session-id wants.
  static String _newSessionId() {
    final r = math.Random.secure();
    final b = [for (var i = 0; i < 16; i++) r.nextInt(256)];
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  static String _q(String s) => "'${s.replaceAll("'", r"'\''")}'";

  /// Stops the review session. What it wrote stays.
  void stop(ReviewKey key) {
    final c = _stops[key];
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Lines [from] to [to] of [path] at [sha], for context around a hunk.
  /// Null when the review is gone.
  Future<List<String>?> fileLines(ReviewKey key, String sha, String path, int from, int to) async {
    final s = await reviewOf(key.project, key.id);
    if (s == null) return null;
    final lines = (await showFile(s.root, sha, path)).split('\n');
    return lines.sublist((from - 1).clamp(0, lines.length), to.clamp(0, lines.length));
  }

  /// What fix commit [sha] changed, against its parent.
  Future<List<DiffFile>> fixDiff(ReviewKey key, String sha) async {
    final s = await _service(key);
    return parseUnifiedDiff(await gitDiff(s.root, '$sha^', sha));
  }

  Future<void> setViewed(ReviewKey key, String path, bool viewed) async {
    await (await reviewOf(key.project, key.id))?.setViewed(path, viewed);
    reviewChanged(key.project, key.id);
  }

  Future<void> setHiddenTags(ReviewKey key, List<String> tags) async {
    await (await reviewOf(key.project, key.id))?.setHiddenTags(tags);
    reviewChanged(key.project, key.id);
  }

  Future<ReviewService> _service(ReviewKey key) async => await reviewOf(key.project, key.id) ?? (throw ReviewError('No review ${key.id}'));

  void _free(ReviewKey key) {
    if (inTerminal(key)) throw ReviewError('The Claude session of this review is open in a terminal. Close that tab first, or carry on there.');
  }

  /// The reviewer's own thread, on a line or a range, or about the whole
  /// change. A question for Claude starts the session that answers.
  Future<void> addThread(
    ReviewKey key, {
    String? path,
    int? line,
    int? endLine,
    String side = 'new',
    required String body,
    required String severity,
    bool askAgent = false,
  }) async {
    if (askAgent) _free(key);
    final t = await (await _service(key))
        .addThread(path: path, line: line, endLine: endLine, side: side, body: body, severity: severity, author: 'user', askAgent: askAgent);
    reviewChanged(key.project, key.id);
    if (t.waiting) unawaited(answer(key));
  }

  /// Your message to Claude on a thread. Starts the session that answers.
  Future<void> reply(ReviewKey key, String threadId, String body) async {
    _free(key);
    await (await _service(key)).reply(threadId, body: body, author: 'user');
    reviewChanged(key.project, key.id);
    unawaited(answer(key));
  }

  /// Asks Claude to fix every thread in [ids], in one session, one commit
  /// each. A thread that needs no code change gets none.
  Future<void> fixAll(ReviewKey key, List<String> ids) async {
    _free(key);
    final s = await _service(key);
    for (final id in ids) {
      await s.reply(id, body: fixNow, author: 'user');
    }
    reviewChanged(key.project, key.id);
    unawaited(answer(key));
  }

  /// Accept or reject the answer of [threadId], or null to undo. While
  /// Claude works on the branch, an accepted fix waits for it to finish.
  /// [revert]: a fix the commits on top need leaves as a revert commit.
  /// On your own merge request, rejecting a reviewer's point answers them:
  /// Claude writes why, and the reply goes out on the next publish.
  Future<void> setDecision(ReviewKey key, String threadId, String? decision, {bool revert = false}) async {
    final s = await _service(key);
    final busy = _onBranch(key);
    final decline = decision == 'reject' && s.review.own && s.thread(threadId).remoteId != null;
    if (decline) _free(key);
    await s.setDecision(threadId, decision, defer: busy, revert: revert);
    if (!busy) await s.applyQueued();
    if (decline) await s.decline(threadId);
    reviewChanged(key.project, key.id);
    if (decline) unawaited(answer(key));
  }

  /// Claude may be committing on the review's branch: a session runs, here
  /// or in its terminal.
  bool _onBranch(ReviewKey key) => (state.runs[key]?.running ?? false) || inTerminal(key);

  /// The fixes accepted while Claude worked go on the branch now. A refusal
  /// is shown, the fix stays accepted and off the branch.
  Future<void> _applyQueued(ReviewKey key, ReviewService? s) async {
    if (s == null || _onBranch(key)) return;
    try {
      await s.applyQueued();
    } on ReviewError catch (e) {
      ref
          .read(noticesProvider.notifier)
          .add(
            NoticeKind.session,
            'A fix did not go on the branch',
            body: e.message,
            route: '/project/${key.project}/review/${key.id}',
            error: true,
            toast: true,
          );
    }
  }

  /// Your own edit of what goes out. Empty: nothing goes out.
  Future<void> setAnswer(ReviewKey key, String threadId, String body) async {
    final s = await _service(key);
    await s.setAnswer(threadId, body: body, author: 'user', suggestion: s.thread(threadId).answer?.suggestion);
    reviewChanged(key.project, key.id);
  }

  /// The folder on the review's branch and the IDE to open it in, making
  /// the fix worktree when no folder has the branch.
  Future<({String dir, String ide})> ideFolder(ReviewKey key) async {
    final s = await _service(key);
    final (dir, error) = await _fixTree(s, key);
    if (dir == null) throw ReviewError(error ?? 'No folder on ${s.review.headRef}');
    final cfg = await ref.read(settingsProvider.future);
    final ide = (await _projectOf(key.project))?.ide ?? cfg.actions.ide;
    reviewChanged(key.project, key.id);
    return (dir: dir, ide: ide);
  }

  /// Where each thread's fix stands, and the files left uncommitted in the fix worktree.
  Future<({Map<String, FixStatus> fixes, List<String> uncommitted})> fixes(ReviewKey key) async {
    final s = await _service(key);
    final statuses = await s.fixStatuses();
    if (statuses.isEmpty) return (fixes: statuses, uncommitted: const <String>[]);
    final (dir, _) = await _fixTree(s, key);
    return (fixes: statuses, uncommitted: dir == null ? const <String>[] : await uncommittedFiles(dir).catchError((_) => const <String>[]));
  }

  Future<PublishPreview> previewPublish(ReviewKey key, String verdict, bool summary) async {
    final s = await _service(key);
    // Your own merge request: replies only, no verdict, no summary.
    return s.review.own ? previewReview(s, verdict: 'comment', summary: false) : previewReview(s, verdict: verdict, summary: summary);
  }

  /// Pushes the accepted fixes, then posts the answers, as new discussions
  /// or replies, and the summary.
  Future<PublishResult> publish(ReviewKey key, String verdict, bool summary) async {
    try {
      final s = await _service(key);
      if (_onBranch(key)) throw ReviewError('Claude is working on this review. Publish when it is done.');
      await s.applyQueued();
      final push = (await s.fixStatuses()).values.any((f) => f.state == 'local');
      if (push) await s.pushFixes(await shellEnvironment());
      final wait = push ? const Duration(seconds: 30) : Duration.zero;
      return await (s.review.own
          ? publishReview(s, verdict: 'comment', summary: false, headWait: wait)
          : publishReview(s, verdict: verdict, summary: summary, headWait: wait));
    } finally {
      reviewChanged(key.project, key.id);
    }
  }

  Future<void> setThreadState(ReviewKey key, String threadId, String state) async {
    await (await _service(key)).setThreadState(threadId, state, 'user');
    reviewChanged(key.project, key.id);
  }

  void _setRun(ReviewKey key, SessionRun run) => state = ReviewsState(runs: {...state.runs, key: run}, changed: state.changed);
}

const reviewToolNames = [
  'get_review',
  'get_diff',
  'get_file',
  'get_ticket',
  'set_ticket',
  'set_ticket_check',
  'set_file_note',
  'set_hunk_note',
  'set_groups',
  'set_checklist',
  'set_features',
  'list_threads',
  'add_thread',
  'reply',
  'set_answer',
  'mark_fixed',
  'set_thread_state',
  'get_round_delta',
  'pull_discussions',
];

/// Added to the steps when a stopped session is carried on.
const resumeNote = '''
## Resuming

An earlier session on this review stopped before the end. What it wrote is
kept: `get_review` and the page already show it. Do not write again a file
note, hunk note or ticket check that exists. Write the notes still missing,
then the steps that were not done (chapters, features, triage, findings),
each over the whole diff.
''';
