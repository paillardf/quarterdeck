// One merge request under review: the overview (what it says it does, whether
// it would merge, the ticket check, the triage), the feature pictures, then
// every file in reading order with its one line note. Noise is hidden by tag,
// with a counter. Threads sit under their line, the inbox on the right lists
// them all; a click on a line's sign column starts one.
import 'dart:async';

import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../sources/chrome.dart';

import '../../actions/launcher.dart';
import '../../core/review/anchors.dart';
import '../../core/review/diff.dart';
import '../../core/review/publish_plan.dart';
import '../../core/review/review.dart';

import '../../state/reviews.dart';
import '../../state/session_run.dart';
import '../../state/settings.dart';
import '../../state/terminals.dart';
import '../../state/ui_memory.dart';
import '../map/class_graph.dart';
import '../map/sequence_view.dart';
import '../project/project_screen.dart';
import '../severity.dart';
import '../../data/review_store.dart' show FixBuriedError;
import '../common.dart';
import '../parts.dart';
import '../theme.dart';
import 'file_diff.dart';
import 'fix_diff_dialog.dart';
import 'publish_dialog.dart';
import 'thread_card.dart';

/// Goes to review [id] of project [project].
void goReview(BuildContext context, String project, String id) => context.go('/project/$project/review/$id');

/// Opens the review of merge request [iid] in Deck. One Deck holds already
/// opens at once, its new head and the author's answers coming in behind; a
/// new one is fetched first, then Claude prepares it.
Future<void> startReview(BuildContext context, WidgetRef ref, String project, String provider, int iid, {bool own = false}) async {
  final id = '$provider-$iid';
  final notifier = ref.read(reviewsProvider.notifier);
  final exists = (await ref.read(projectReviewsProvider(project).future)).any((r) => r.id == id);
  // Your own merge request: pull the reviewers' threads, then Claude drafts
  // your answers to the ones waiting on you.
  if (own) {
    Future<void> feedback() => notifier.open(project, iid, own: true).then((opened) => notifier.feedbackThenAnalyze((project: project, id: opened)));
    if (exists) {
      if (context.mounted) goReview(context, project, id);
      unawaited(feedback().then((_) {}, onError: (_) {}));
      return;
    }
    final opened = await notifier.open(project, iid, own: true);
    unawaited(notifier.feedbackThenAnalyze((project: project, id: opened)));
    if (context.mounted) goReview(context, project, opened);
    return;
  }
  if (exists) {
    if (context.mounted) goReview(context, project, id);
    unawaited(notifier.open(project, iid).then((_) {}, onError: (_) {}));
    return;
  }
  final opened = await notifier.open(project, iid);
  unawaited(notifier.prepare(project, opened));
  if (context.mounted) goReview(context, project, opened);
}

/// Opens the review of a local branch checked out in [folder]. A new one
/// first asks for the target branch, then starts preparing. Opening one Deck holds refreshes its diff.
Future<void> startLocalReview(BuildContext context, WidgetRef ref, String project, String folder, String branch) async {
  final notifier = ref.read(reviewsProvider.notifier);
  final id = Reviews.localReviewId(branch);
  final exists = (await ref.read(projectReviewsProvider(project).future)).any((r) => r.id == id);
  // A new review: pick what it diffs from before Claude reads it.
  String? base;
  if (!exists) {
    final choices = await notifier.projectBranches(project);
    if (!context.mounted) return;
    base = await pickBranch(context, choices, await notifier.defaultBaseOf(project));
    if (base == null) return;
  }
  final opened = await notifier.openLocal(project, folder, branch, base: base);
  if (!exists) unawaited(notifier.prepare(project, opened));
  if (context.mounted) goReview(context, project, opened);
}

/// A branch from [choices], filtered as you type. Null when cancelled.
Future<String?> pickBranch(BuildContext context, List<String> choices, String current) => showDialog<String>(
  context: context,
  builder: (_) => _BranchPicker(choices: choices, current: current),
);

class _BranchPicker extends StatefulWidget {
  const _BranchPicker({required this.choices, required this.current});

  final List<String> choices;
  final String current;

  @override
  State<_BranchPicker> createState() => _BranchPickerState();
}

class _BranchPickerState extends State<_BranchPicker> {
  var _filter = '';

  @override
  Widget build(BuildContext context) {
    // The current target first, so Enter keeps it.
    final shown = [
      for (final b in [widget.current, ...widget.choices.where((b) => b != widget.current)])
        if (b.toLowerCase().contains(_filter.toLowerCase())) b,
    ];
    return AlertDialog(
      title: const Text('Target branch'),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Filter branches', prefixIcon: Icon(Icons.search_rounded, size: 18)),
              onChanged: (v) => setState(() => _filter = v),
              onSubmitted: (_) => shown.isEmpty ? null : Navigator.pop(context, shown.first),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Material(
                type: MaterialType.transparency,
                child: ListView(
                  children: [
                    for (final b in shown)
                      ListTile(
                        dense: true,
                        selected: b == widget.current,
                        title: Text(b, style: mono(context.t.bodyMedium!)),
                        onTap: () => Navigator.pop(context, b),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}

enum SideMode { files, chapters, tree }

/// Every button on the page bar, the thread panel and the page itself: one height.
const _compact = ButtonStyle(visualDensity: VisualDensity.compact);

/// The files of a review in the order the page shows them: by chapter when
/// there are chapters (a file in none goes last), else as git lists them.
List<({String? chapter, DiffFile file})> readingOrder(DiffSnapshot snap, Review r) {
  final byPath = {for (final f in snap.files) f.path: f};
  final seen = <String>{};
  final out = <({String? chapter, DiffFile file})>[];
  for (final g in r.groups) {
    for (final it in g.items) {
      final f = byPath[it.path];
      if (f != null && seen.add(f.path)) out.add((chapter: g.title, file: f));
    }
  }
  for (final f in snap.files) {
    if (seen.add(f.path)) out.add((chapter: r.groups.isEmpty ? null : 'Unclaimed', file: f));
  }
  return out;
}

/// Every tag a file carries: the classifier's and the session's.
List<String> tagsOf(DiffFile f, Review r) => [...f.tags, ...?r.fileNotes.where((n) => n.path == f.path).firstOrNull?.extraTags];

class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key, required this.project, required this.id});

  final String project, id;

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  var _split = false;
  var _mode = SideMode.chapters;
  var _inbox = true;

  /// The form for a comment about the whole change is open.
  var _general = false;
  var _pushing = false;

  /// The lines a new thread goes on, while its form is open.
  ({String path, String side, int from, int to})? _pick;
  final _scroll = ScrollController();
  final _keys = <String, GlobalKey>{};

  ReviewKey get _key => (project: widget.project, id: widget.id);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _jump(String path, {Duration duration = const Duration(milliseconds: 250)}) {
    final ctx = _keys[path]?.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: duration, alignment: .02);
  }

  /// The context of each thread card on screen, so the inbox scrolls to the
  /// card itself. Not a GlobalKey: the lazy diff list may build a card at its
  /// new row before dropping the old one.
  final _cards = <String, BuildContext>{};

  /// The last thread opened from the inbox: its file shows it.
  ({String path, String side, int line, String id, int seq})? _reveal;

  /// Puts thread [t]'s card on screen at once. A card on a line goes through
  /// its file, which opens what hides it and jumps to it. One whose line left
  /// the diff sits with the whole change threads at the top, always built.
  void _openThread(Thread t) {
    final a = t.anchor, snap = ref.read(reviewDiffProvider(_key)).value;
    final re = a == null || snap == null ? null : reanchor(a, snap);
    if (re != null && re.status != 'outdated') {
      setState(() => _reveal = (path: a!.path, side: re.anchor.side, line: re.anchor.endLine, id: t.id, seq: (_reveal?.seq ?? 0) + 1));
      return;
    }
    final c = _cards[t.id];
    if (c != null && c.mounted) Scrollable.ensureVisible(c, alignment: .15);
  }

  Reviews get _reviews => ref.read(reviewsProvider.notifier);

  void _onLine(String path, String side, int line, {bool extend = false}) => setState(() {
    final p = _pick;
    _pick = extend && p != null && p.path == path && p.side == side
        ? (path: path, side: side, from: line < p.from ? line : p.from, to: line > p.to ? line : p.to)
        : (path: path, side: side, from: line, to: line);
  });

  /// Claude is answering the threads now.
  bool _answering = false;

  Map<String, FixStatus> _fixes = const {};

  /// Why Claude cannot be asked now.
  String? _locked;

  /// The merge request's author, to tell which threads wait on you.
  String _author = '';

  /// The review has a merge request to publish to.
  bool _canPost = true;

  Widget _card(Thread t, {bool outdated = false, bool own = false}) => _Tracked(
    key: ValueKey(t.id),
    id: t.id,
    cards: _cards,
    child: _threadCard(t, outdated: outdated, own: own),
  );

  /// A fix the commits on top need cannot simply leave the branch: ask
  /// before undoing it with a revert commit.
  Future<void> _decide(Thread t, String? d) async {
    try {
      await _reviews.setDecision(_key, t.id, d);
    } on FixBuriedError catch (e) {
      if (!mounted) return;
      final ok = await confirm(
        context,
        title: 'Revert the Fix',
        text: '${e.message}\n\nThe revert stays local until the next publish pushes it.',
        action: 'Revert',
      );
      if (ok) await _reviews.setDecision(_key, t.id, d, revert: true);
    }
  }

  void _showFix(String sha) => showDialog<void>(
    context: context,
    builder: (_) => FixDiffDialog(sha: sha, files: _reviews.fixDiff(_key, sha)),
  );

  Widget _threadCard(Thread t, {bool outdated = false, bool own = false}) => ThreadCard(
    thread: t,
    outdated: outdated,
    own: own,
    fix: _fixes[t.id],
    onShowFix: _showFix,
    locked: _locked,
    thinking: _answering,
    onAsk: (b) => _reviews.reply(_key, t.id, b),
    onAnswer: (b) => _reviews.setAnswer(_key, t.id, b),
    onState: (s) => _reviews.setThreadState(_key, t.id, s),
    onDecide: (d) => _decide(t, d),
    onTerminal: () => _reviews.openInTerminal(_key, thread: t),
    quiet: quietOnForge(t, own: own, author: _author),
    canPost: _canPost && postsOnForge(t, own: own),
  );

  /// Thread cards and the new thread form, per file and line. Threads whose
  /// line left the diff, and the ones about the whole change, go in [loose].
  Map<String, Map<(String, int), List<Widget>>> _placeThreads(Review r, DiffSnapshot snap, List<Widget> loose) {
    final out = <String, Map<(String, int), List<Widget>>>{};
    for (final t in r.threads) {
      final a = t.anchor;
      if (a == null) {
        loose.add(_card(t, own: r.own));
        continue;
      }
      final re = reanchor(a, snap);
      if (re.status == 'outdated') {
        loose.add(_card(t, outdated: true, own: r.own));
        continue;
      }
      ((out[a.path] ??= {})[(re.anchor.side, re.anchor.endLine)] ??= []).add(_card(t, own: r.own));
    }
    if (_pick case final p?) {
      final where = p.from == p.to ? '${p.side} line ${p.from}' : '${p.side} lines ${p.from} to ${p.to}';
      ((out[p.path] ??= {})[(p.side, p.to)] ??= []).add(
        NewThreadForm(
          key: const ValueKey('new-thread'),
          label: 'New comment on $where',
          onSubmit: (body, severity, ask) async {
            await _reviews.addThread(_key, path: p.path, line: p.from, endLine: p.to, side: p.side, body: body, severity: severity, askAgent: ask);
            if (mounted) setState(() => _pick = null);
          },
          onCancel: () => setState(() => _pick = null),
        ),
      );
    }
    return out;
  }

  Widget? _publish(Review r) => r.mr == null
      ? (r.local ? _push(r) : null)
      : FilledButton.icon(
          style: _compact,
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => PublishDialog(
              mr: r.mr!,
              own: r.own,
              preview: (v, s) => _reviews.previewPublish(_key, v, s),
              publish: (v, s) => _reviews.publish(_key, v, s),
              summary: ref.read(uiMemoryProvider).summaryNote,
              onSummary: ref.read(uiMemoryProvider).setSummaryNote,
              onBrowser: () => openLink(
                Uri.parse(r.mr!.url),
                ref.read(settingsProvider).value?.projects.where((p) => p.id == widget.project).firstOrNull?.browserProfile ??
                    ref.read(settingsProvider).value?.actions.browserProfile,
              ),
            ),
          ),
          icon: const Icon(Icons.send_rounded, size: 16),
          label: Text(r.own ? 'Send replies' : 'Publish review'),
        );

  /// A local branch with no merge request: its commits, accepted fixes
  /// included, go to the same branch on origin.
  Widget _push(Review r) => Tooltip(
    message: 'Push ${r.headRef} to origin. No merge request is open on it.',
    child: FilledButton.icon(
      style: _compact,
      onPressed: _pushing
          ? null
          : () async {
              setState(() => _pushing = true);
              try {
                await _reviews.push(_key);
                if (mounted) showToast(context, 'Pushed ${r.headRef}');
              } catch (e) {
                if (mounted) showToast(context, '$e');
              } finally {
                if (mounted) setState(() => _pushing = false);
              }
            },
      icon: const Icon(Icons.upload_rounded, size: 16),
      label: const Text('Push'),
    ),
  );

  /// Called before the page changes (the review, a run, the fix bar): notes
  /// the first card on screen, and after the frame scrolls so
  /// it sits at the same place again. Flutter keeps the scroll offset, not
  /// what you read, so a card growing or folding above moved the page.
  void _holdPlace() {
    if (!_scroll.hasClients) return;
    // At the top you read the top: let the page grow under it.
    if (_scroll.position.pixels <= 0) return;
    final view = _scroll.position.context.notificationContext;
    final top = view == null ? null : _topOf(view);
    if (top == null) return;
    final bottom = top + _scroll.position.viewportDimension;
    String? id;
    double? at;
    // The first card on screen, even one whose top is above it (you read its
    // chat): it grows downward, nothing you see moves.
    for (final e in _cards.entries) {
      final y = _topOf(e.value), end = _bottomOf(e.value);
      if (y == null || end == null || end < top || y > bottom || (at != null && y >= at)) continue;
      (id, at) = (e.key, y);
    }
    // No card on screen: hold the code line a third of the way down.
    final line = id == null ? _lineAt(view!, top + (bottom - top) / 3) : null;
    final was = at ?? (line == null ? null : _boxTop(line));
    if (was == null) return;
    final anchor = id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = anchor == null ? null : _cards[anchor];
      final y = c != null ? _topOf(c) : (line == null ? null : _boxTop(line));
      if (y == null || y == was || !_scroll.hasClients) return;
      final pos = _scroll.position;
      pos.jumpTo((pos.pixels + y - was).clamp(pos.minScrollExtent, pos.maxScrollExtent));
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(reviewProvider(_key), (_, _) => _holdPlace());
    ref.listen(reviewFixesProvider(_key), (_, _) => _holdPlace());
    ref.listen(reviewDiffProvider(_key), (_, _) => _holdPlace());
    ref.listen(reviewsProvider.select((s) => s.runs[_key]), (_, _) => _holdPlace());
    final review = ref.watch(reviewProvider(_key));
    final diff = ref.watch(reviewDiffProvider(_key));
    final run = ref.watch(reviewsProvider).runs[_key];
    _answering = run != null && run.running && run.kind == 'answer';
    final fixes = ref.watch(reviewFixesProvider(_key)).value;
    _fixes = fixes?.fixes ?? const {};
    // A terminal tab on this review's session opening or closing locks or frees the threads.
    final inTerminal = ref.watch(terminalsProvider.select((t) => t.running(Reviews.terminalKey(_key)) != null));
    _locked = inTerminal ? 'The Claude session of this review is open in a terminal. Carry on there, or close that tab.' : null;
    final r = review.value;
    _author = r?.mr?.author ?? '';
    _canPost = r?.mr != null;
    if (review.isLoading && r == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (r == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('No review "${widget.id}"', style: context.t.titleMedium),
              const SizedBox(height: 12),
              FilledButton(onPressed: () => goProject(context, widget.project, const MrsPlace()), child: const Text('Back to Merge Requests')),
            ],
          ),
        ),
      );
    }
    final snap = diff.value;
    final hidden = {...(r.hiddenTags ?? snap?.hidden ?? hiddenByDefault)};
    final order = snap == null ? const <({String? chapter, DiffFile file})>[] : readingOrder(snap, r);
    final visible = [
      for (final e in order)
        if (e.file.path == _reveal?.path || !tagsOf(e.file, r).any(hidden.contains)) e,
    ];
    for (final e in order) {
      _keys.putIfAbsent(e.file.path, GlobalKey.new);
    }
    final loose = <Widget>[];
    final placed = snap == null ? const <String, Map<(String, int), List<Widget>>>{} : _placeThreads(r, snap, loose);
    return Focus(
      autofocus: true,
      // S switches split view, but never while you type in a text field.
      onKeyEvent: (_, e) {
        if (e is! KeyDownEvent ||
            e.logicalKey != LogicalKeyboardKey.keyS ||
            HardwareKeyboard.instance.isMetaPressed ||
            HardwareKeyboard.instance.isControlPressed) {
          return KeyEventResult.ignored;
        }
        if (FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null) return KeyEventResult.ignored;
        setState(() => _split = !_split);
        return KeyEventResult.handled;
      },
      child: Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Sidebar(
              review: r,
              projectName: ref.watch(settingsProvider).value?.projects.where((p) => p.id == widget.project).firstOrNull?.name ?? widget.project,
              snap: snap,
              order: order,
              hidden: hidden,
              mode: _mode,
              onMode: (m) => setState(() => _mode = m),
              onTags: (t) => ref.read(reviewsProvider.notifier).setHiddenTags(_key, t),
              onFile: _jump,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TopBar(
                    review: r,
                    split: _split,
                    onSplit: (v) => setState(() => _split = v),
                    run: run,
                    threads: openCount(r.threads),
                    headSha: snap?.headSha,
                    inbox: _inbox,
                    onInbox: () => setState(() => _inbox = !_inbox),
                    onPrepare: () => ref.read(reviewsProvider.notifier).prepare(widget.project, widget.id),
                    onFindings: () => ref.read(reviewsProvider.notifier).prepare(widget.project, widget.id, findings: true),
                    onResume: () => ref.read(reviewsProvider.notifier).prepare(widget.project, widget.id, resume: true),
                    onStop: () => ref.read(reviewsProvider.notifier).stop(_key),
                    inTerminal: inTerminal,
                    onTerminal: () => _reviews.openInTerminal(_key),
                    onDelete: () async {
                      if (await deleteReview(context, ref, _key) && context.mounted) goProject(context, widget.project, const MrsPlace());
                    },
                    folder: ref.watch(reviewFolderProvider(_key)).value,
                    onIde: () => _reviews.ideFolder(_key).then((f) => openInIde(f.ide, f.dir, '', null)).catchError((Object e) {
                      if (context.mounted) showToast(context, '$e');
                    }),
                    onBase: r.folder == null
                        ? null
                        : () async {
                            try {
                              final choices = await _reviews.baseChoices(_key);
                              if (!context.mounted) return;
                              final base = await pickBranch(context, choices, r.baseRef);
                              if (base != null && base != r.baseRef) await _reviews.setBase(_key, base);
                            } catch (e) {
                              if (context.mounted) showToast(context, '$e');
                            }
                          },
                    onBrowser: () => openLink(
                      Uri.parse(r.mr!.url),
                      ref.read(settingsProvider).value?.projects.where((p) => p.id == widget.project).firstOrNull?.browserProfile ??
                          ref.read(settingsProvider).value?.actions.browserProfile,
                    ),
                  ),
                  if (fixes != null && fixes.fixes.isNotEmpty)
                    _FixBar(fixes: fixes.fixes, uncommitted: fixes.uncommitted, pushLabel: r.mr == null ? 'Push' : 'the next send'),
                  Expanded(
                    child: switch (diff) {
                      AsyncError(:final error) => Center(
                        child: Text('$error', style: context.t.bodySmall?.copyWith(color: context.c.red)),
                      ),
                      _ when snap == null => const Center(child: CircularProgressIndicator()),
                      _ => CustomScrollView(
                        controller: _scroll,
                        slivers: [
                          SliverToBoxAdapter(
                            child: _Overview(review: r, snap: snap, visible: visible.length, keyOf: _key, onFile: _jump),
                          ),
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Text('ABOUT THE WHOLE CHANGE', style: context.t.labelSmall),
                                      const SizedBox(width: 12),
                                      Tooltip(
                                        message: 'A comment about the whole change: scope, a missing test, the branch itself',
                                        child: OutlinedButton.icon(
                                          style: _compact,
                                          onPressed: () => setState(() => _general = true),
                                          icon: const Icon(Icons.add, size: 16),
                                          label: const Text('General comment'),
                                        ),
                                      ),
                                      if (_publish(r) case final publish?) ...[const SizedBox(width: 8), publish],
                                    ],
                                  ),
                                  if (_general)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: NewThreadForm(
                                        label: 'New comment on the whole change',
                                        onSubmit: (body, severity, ask) async {
                                          await _reviews.addThread(_key, body: body, severity: severity, askAgent: ask);
                                          if (mounted) setState(() => _general = false);
                                        },
                                        onCancel: () => setState(() => _general = false),
                                      ),
                                    ),
                                  for (final w in loose) Padding(padding: const EdgeInsets.only(top: 8), child: w),
                                ],
                              ),
                            ),
                          ),
                          if (r.features.isNotEmpty)
                            SliverToBoxAdapter(
                              child: _Features(review: r, project: widget.project),
                            ),
                          for (final (i, e) in visible.indexed) ...[
                            if (e.chapter != null && (i == 0 || visible[i - 1].chapter != e.chapter))
                              SliverToBoxAdapter(
                                child: _ChapterHead(review: r, title: e.chapter!),
                              ),
                            // FileDiffView is a sliver: only the rows on screen are built.
                            SliverPadding(
                              key: _keys[e.file.path],
                              padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
                              sliver: _FileBlock(
                                review: r,
                                file: e.file,
                                snap: snap,
                                split: _split,
                                keyOf: _key,
                                below: placed[e.file.path] ?? const {},
                                onLine: (side, line, {extend = false}) => _onLine(e.file.path, side, line, extend: extend),
                                selected: _pick?.path == e.file.path ? (side: _pick!.side, from: _pick!.from, to: _pick!.to) : null,
                                reveal: _reveal?.path == e.file.path
                                    ? (side: _reveal!.side, line: _reveal!.line, card: ValueKey(_reveal!.id), seq: _reveal!.seq)
                                    : null,
                              ),
                            ),
                          ],
                          const SliverToBoxAdapter(child: SizedBox(height: 80)),
                        ],
                      ),
                    },
                  ),
                ],
              ),
            ),
            if (_inbox)
              Container(
                width: 360,
                decoration: BoxDecoration(
                  border: Border(left: BorderSide(color: context.c.sep)),
                ),
                child: ThreadInbox(
                  threads: r.threads,
                  fixes: _fixes,
                  onShowFix: _showFix,
                  onOpen: _openThread,
                  onClose: () => setState(() => _inbox = false),
                  publish: _publish(r),
                  canPost: r.mr != null,
                  own: r.own,
                  locked: _locked,
                  // Fixes go on a branch that is yours.
                  onFixAll: r.own || r.local ? (ids) => _reviews.fixAll(_key, ids) : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

double? _bottomOf(BuildContext c) {
  final box = c.mounted ? c.findRenderObject() : null;
  return box is RenderBox && box.attached && box.hasSize ? box.localToGlobal(Offset(0, box.size.height)).dy : null;
}

/// Where the top of [c]'s box is on screen, or null when it is not laid out.
double? _topOf(BuildContext c) => c.mounted ? _boxTop(c.findRenderObject()) : null;

double? _boxTop(RenderObject? box) => box is RenderBox && box.attached && box.hasSize ? box.localToGlobal(Offset.zero).dy : null;

/// The smallest box at height [y] of the list in [view]: a line of code.
RenderBox? _lineAt(BuildContext view, double y) {
  final list = view.findRenderObject();
  if (list is! RenderBox || !list.attached) return null;
  final x = list.localToGlobal(Offset(list.size.width / 2, 0)).dx;
  final hits = HitTestResult();
  WidgetsBinding.instance.hitTestInView(hits, Offset(x, y), View.of(view).viewId);
  for (final e in hits.path) {
    if (e.target case final RenderBox b when b.hasSize && b.size.height < list.size.height / 4) return b;
  }
  return null;
}

/// Keeps its context in [cards] under [id] while it is mounted.
class _Tracked extends StatefulWidget {
  const _Tracked({super.key, required this.id, required this.cards, required this.child});

  final String id;
  final Map<String, BuildContext> cards;
  final Widget child;

  @override
  State<_Tracked> createState() => _TrackedState();
}

class _TrackedState extends State<_Tracked> {
  @override
  void dispose() {
    if (identical(widget.cards[widget.id], context)) widget.cards.remove(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    widget.cards[widget.id] = context;
    return widget.child;
  }
}

class _FileBlock extends ConsumerWidget {
  const _FileBlock({
    required this.review,
    required this.file,
    required this.snap,
    required this.split,
    required this.keyOf,
    this.below = const {},
    this.onLine,
    this.selected,
    this.reveal,
  });

  final Review review;
  final DiffFile file;
  final DiffSnapshot snap;
  final bool split;
  final ReviewKey keyOf;
  final Map<(String, int), List<Widget>> below;
  final void Function(String side, int line, {bool extend})? onLine;
  final ({String side, int from, int to})? selected;
  final ({String side, int line, Key card, int seq})? reveal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final note = review.fileNotes.where((n) => n.path == file.path).firstOrNull;
    final viewedAt = review.viewed[file.path];
    return FileDiffView(
      file: file,
      split: split,
      below: below,
      onLine: onLine,
      selected: selected,
      reveal: reveal,
      note: note?.summary,
      hunkNotes: {
        for (final h in review.hunkNotes)
          if (h.path == file.path) h.hunkRef: h.summary,
      },
      viewed: viewedAt != null,
      onViewed: (v) => ref.read(reviewsProvider.notifier).setViewed(keyOf, file.path, v),
      loadContext: file.status == 'deleted' ? null : (from, to) => ref.read(reviewsProvider.notifier).fileLines(keyOf, snap.headSha, file.path, from, to),
      onOpen: (line) => codeOpener(ref, keyOf.project)(file.path, line),
    );
  }
}

/// Asks, then deletes review [key] with its fix worktree and fetched branch.
/// True once it is gone; a refusal (edits in the worktree, a session at
/// work) shows in a snack bar.
Future<bool> deleteReview(BuildContext context, WidgetRef ref, ReviewKey key) async {
  final ok = await confirm(
    context,
    title: 'Delete this review?',
    text:
        'Deck drops its notes, threads and answers not published yet, its fix worktree, and the branch it fetched '
        'for the merge request. Fix commits not pushed are lost. What is published on the forge stays.',
    action: 'Delete Review',
    destructive: true,
  );
  if (!ok) return false;
  try {
    await ref.read(reviewsProvider.notifier).delete(key);
    return true;
  } catch (e) {
    if (context.mounted) showToast(context, '$e');
    return false;
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.review,
    required this.split,
    required this.onSplit,
    required this.run,
    required this.threads,
    this.headSha,
    required this.inbox,
    required this.onInbox,
    required this.onPrepare,
    required this.onFindings,
    required this.onResume,
    required this.onStop,
    this.inTerminal = false,
    this.onTerminal,
    required this.onDelete,
    this.folder,
    this.onIde,
    this.onBase,
    required this.onBrowser,
  });

  /// Picks the branch a local review diffs from. Null on a merge request.
  final VoidCallback? onBase;

  final Review review;

  /// Opens the merge request in the project's browser profile.
  final VoidCallback onBrowser;

  /// The folder on the review's branch. Null: none yet.
  final String? folder;

  /// Opens that folder in the IDE, making the fix worktree if needed.
  final VoidCallback? onIde;

  /// Deletes the review, after asking.
  final VoidCallback onDelete;
  final bool split;

  /// The review's Claude session is open in a Deck terminal.
  final bool inTerminal;

  /// Opens it there. Null before the first session.
  final VoidCallback? onTerminal;
  final ValueChanged<bool> onSplit;
  final SessionRun? run;

  /// Threads still to triage, on the inbox button.
  final int threads;

  /// The head the page shows: past the last published round, the next round can start.
  final String? headSha;
  final bool inbox;
  final VoidCallback onInbox;
  final VoidCallback onPrepare, onFindings, onResume, onStop;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final mr = review.mr;
    final sep = mr?.provider == 'github' ? '#' : '!';
    final empty = review.fileNotes.isEmpty && review.groups.isEmpty;
    final running = run?.running ?? false;
    final published = review.rounds.where((r) => r.publishedAt != null).lastOrNull;
    final next = published != null && headSha != null && headSha != published.headSha ? published.number + 1 : null;
    final res = run?.result;
    final String? status;
    if (inTerminal) {
      status = 'The Claude session of this review is open in a terminal. Deck asks Claude nothing here until you close that tab.';
    } else if (run == null) {
      status = null;
    } else if (res == null) {
      status = [run!.progress('steps', DateTime.now()), 'Claude is working on the review: ${run!.step}'].whereType<String>().join(' · ');
    } else if (res.error != null) {
      status = 'The review session stopped: ${res.error}';
    } else {
      status =
          '${switch (run!.kind) {
            'answer' => 'Answered',
            'feedback' => 'Wrote your replies',
            _ => 'Prepared',
          }} in ${res.seconds < 60 ? '${res.seconds} s' : '${(res.seconds / 60).round()} min'} for \$${res.costUsd.toStringAsFixed(2)}.';
    }
    return Material(
      color: c.bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 20, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        mr?.title ?? (review.folder != null ? review.headRef : review.id),
                        style: context.t.headlineSmall?.copyWith(fontSize: 22),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              [
                                if (mr != null) '$sep${mr.iid}',
                                if (mr?.author.isNotEmpty ?? false) mr!.author,
                                if (mr != null) '${mr.sourceBranch} → ${mr.targetBranch}',
                                if (review.local) 'your local branch',
                                if (published != null)
                                  'round ${published.number} published${published.verdict == null ? '' : ', ${published.verdict!.replaceAll('_', ' ')}'}',
                                if (onBase != null) '${review.headRef} →',
                              ].join(' · '),
                              overflow: TextOverflow.ellipsis,
                              style: context.t.bodySmall,
                            ),
                          ),
                          if (onBase != null)
                            InkWell(
                              onTap: onBase,
                              borderRadius: BorderRadius.circular(4),
                              child: Tooltip(
                                message: 'Change the target branch',
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        review.baseRef,
                                        style: context.t.bodySmall?.copyWith(color: c.blue, fontWeight: FontWeight.w600),
                                      ),
                                      Icon(Icons.arrow_drop_down_rounded, size: 16, color: c.blue),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(Icons.folder_outlined, size: 13, color: c.label3),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              folder == null ? 'No folder on this branch yet' : tildeHome(folder!),
                              style: folder == null ? context.t.bodySmall?.copyWith(fontSize: 11.5) : mono(context.t.bodySmall!.copyWith(fontSize: 11.5)),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (onIde != null)
                  IconButton(
                    tooltip: folder == null ? 'Make a worktree on ${review.headRef} and open it in the IDE' : 'Open this folder in the IDE',
                    visualDensity: VisualDensity.compact,
                    onPressed: onIde,
                    icon: const Icon(Icons.code_rounded, size: 18),
                  ),
                if (mr != null)
                  IconButton(
                    tooltip: 'Open in the browser',
                    visualDensity: VisualDensity.compact,
                    onPressed: onBrowser,
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  ),
                if (onTerminal != null)
                  IconButton(
                    tooltip: inTerminal ? 'Show the terminal' : 'Talk about this merge request with Claude in a terminal',
                    visualDensity: VisualDensity.compact,
                    onPressed: running ? null : onTerminal,
                    icon: const Icon(Icons.terminal_rounded, size: 18),
                  ),
                IconButton(
                  tooltip: 'Delete this review',
                  visualDensity: VisualDensity.compact,
                  onPressed: running ? null : onDelete,
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                ),
                const SizedBox(width: 4),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: false, label: Text('Unified')),
                    ButtonSegment(value: true, label: Text('Split')),
                  ],
                  selected: {split},
                  onSelectionChanged: (s) => onSplit(s.first),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: inbox ? 'Hide the threads' : 'Show the threads',
                  isSelected: inbox,
                  visualDensity: VisualDensity.compact,
                  onPressed: onInbox,
                  icon: Badge(isLabelVisible: threads > 0, label: Text('$threads'), child: const Icon(Icons.forum_outlined, size: 20)),
                ),
                const SizedBox(width: 6),
                if (running)
                  OutlinedButton.icon(style: _compact, onPressed: onStop, icon: const Icon(Icons.stop_rounded, size: 16), label: const Text('Stop'))
                else ...[
                  if (!empty && res?.error != null) ...[
                    FilledButton.icon(style: _compact, onPressed: onResume, icon: const Icon(Icons.play_arrow_rounded, size: 16), label: const Text('Resume')),
                    const SizedBox(width: 6),
                  ],
                  if (next != null) ...[
                    Tooltip(
                      message: 'The author pushed: Claude reads what changed since round ${published!.number} and answers each open thread',
                      child: FilledButton.icon(
                        style: _compact,
                        onPressed: onPrepare,
                        icon: const Icon(Icons.replay_rounded, size: 16),
                        label: Text('Start round $next'),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (empty)
                    FilledButton.icon(
                      style: _compact,
                      onPressed: onPrepare,
                      icon: const Icon(Icons.auto_awesome_outlined, size: 16),
                      label: Text(review.own ? 'Analyze with Claude' : 'Prepare with Claude'),
                    )
                  else
                    _ClaudeMenu(onFindings: onFindings, onPrepare: next == null ? onPrepare : null, onTerminal: onTerminal),
                ],
              ],
            ),
            if (status != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  if (running)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  Expanded(
                    child: Text(status, style: context.t.bodySmall, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The fixes Claude made: how many wait for your Accept, how many are on the
/// branch and go out with the next Send, what is left uncommitted.
class _FixBar extends StatelessWidget {
  const _FixBar({required this.fixes, required this.uncommitted, this.pushLabel = 'the next send'});

  final Map<String, FixStatus> fixes;
  final List<String> uncommitted;

  /// What pushes the accepted fixes: the next send, or Push on a local
  /// review with no merge request.
  final String pushLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.c, all = fixes.values;
    int count(String state) => all.where((f) => f.state == state).length;
    final pending = count('pending'),
        queued = count('queued'),
        local = count('local'),
        pushed = count('pushed'),
        gone = count('gone'),
        files = uncommitted.length;
    final parts = [
      if (pending > 0) '$pending fix${pending == 1 ? '' : 'es'} wait${pending == 1 ? 's' : ''} for your Accept',
      if (queued > 0) '$queued accepted, on the branch when Claude is done',
      if (local > 0) '$local accepted, pushed with $pushLabel',
      if (files > 0) '$files file${files == 1 ? '' : 's'} changed, not committed',
      if (gone > 0) '$gone fix${gone == 1 ? '' : 'es'} no longer on the branch',
      if (pushed > 0) '$pushed pushed',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    final color = pending > 0 || local > 0 || files > 0 ? c.orange : c.green;
    return TintBox(
      dense: true,
      color: color,
      margin: const EdgeInsets.fromLTRB(24, 0, 20, 8),
      child: Row(
        children: [
          Icon(Icons.build_rounded, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(parts.join(' · '), style: context.t.bodySmall)),
        ],
      ),
    );
  }
}

/// What Claude can do again on a prepared review, each with what it changes.
class _ClaudeMenu extends StatelessWidget {
  const _ClaudeMenu({required this.onFindings, this.onPrepare, this.onTerminal});

  final VoidCallback onFindings;

  /// Null before the first session.
  final VoidCallback? onTerminal;

  /// Null once a round is waiting: Start round N does that job then.
  final VoidCallback? onPrepare;

  @override
  Widget build(BuildContext context) {
    Widget item(IconData icon, String title, String detail, VoidCallback onPressed) => MenuItemButton(
      leadingIcon: Icon(icon, size: 18),
      onPressed: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: SizedBox(
          width: 280,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: context.t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              Text(detail, style: context.t.bodySmall),
            ],
          ),
        ),
      ),
    );
    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        item(Icons.bug_report_outlined, 'Look for more bugs', 'Claude reads the diff again and adds new findings. Nothing else changes.', onFindings),
        if (onTerminal != null)
          item(
            Icons.terminal_rounded,
            'Open the session in a terminal',
            'The same Claude session, with the review tools. Deck asks it nothing while the tab is open.',
            onTerminal!,
          ),
        if (onPrepare != null)
          item(
            Icons.refresh_rounded,
            'Prepare again from scratch',
            'Claude rewrites the file notes, chapters, features and ticket check, then looks for bugs. Your threads stay.',
            onPrepare!,
          ),
      ],
      builder: (context, menu, _) => OutlinedButton.icon(
        style: _compact,
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        icon: const Icon(Icons.auto_awesome_outlined, size: 16),
        label: const Row(mainAxisSize: MainAxisSize.min, children: [Text('Claude'), Icon(Icons.arrow_drop_down_rounded, size: 18)]),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.review,
    required this.projectName,
    required this.snap,
    required this.order,
    required this.hidden,
    required this.mode,
    required this.onMode,
    required this.onTags,
    required this.onFile,
  });

  final Review review;

  /// The project's name from Settings, its id when it has none.
  final String projectName;
  final DiffSnapshot? snap;
  final List<({String? chapter, DiffFile file})> order;
  final Set<String> hidden;
  final SideMode mode;
  final ValueChanged<SideMode> onMode;
  final ValueChanged<List<String>> onTags;
  final ValueChanged<String> onFile;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final counts = <String, int>{};
    for (final e in order) {
      for (final t in tagsOf(e.file, review).toSet()) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    final hiddenFiles = order.where((e) => tagsOf(e.file, review).any(hidden.contains)).length;
    final visible = [
      for (final e in order)
        if (!tagsOf(e.file, review).any(hidden.contains)) e,
    ];

    Widget fileRow(DiffFile f, {double indent = 0, String? label}) {
      final note = review.fileNotes.where((n) => n.path == f.path).firstOrNull;
      final viewedAt = review.viewed[f.path];
      final changed = viewedAt != null && snap != null && viewedAt != snap!.headSha;
      return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => onFile(f.path),
        child: Padding(
          padding: EdgeInsets.fromLTRB(8 + indent, 5, 8, 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 6),
                child: Icon(viewedAt != null ? Icons.check_circle_rounded : Icons.circle_outlined, size: 13, color: viewedAt != null ? c.green : c.label3),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label ?? f.path.split('/').last,
                      overflow: TextOverflow.ellipsis,
                      style: context.t.bodySmall!.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600, color: viewedAt != null ? c.label2 : c.label),
                    ),
                    if (note != null) Text(note.summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.t.bodySmall?.copyWith(fontSize: 11.5)),
                  ],
                ),
              ),
              if (changed)
                Tooltip(
                  message: 'Changed since you viewed it',
                  child: CircleAvatar(radius: 3.5, backgroundColor: c.orange),
                ),
              const SizedBox(width: 6),
              Text('+${f.realAdditions} −${f.realDeletions}', style: context.t.bodySmall!.copyWith(fontSize: 10.5, color: c.label3)),
            ],
          ),
        ),
      );
    }

    final rows = <Widget>[];
    switch (mode) {
      case SideMode.files:
        rows.addAll([for (final e in visible) fileRow(e.file, label: e.file.path)]);
      case SideMode.chapters:
        String? last;
        for (final e in visible) {
          if (e.chapter != last && e.chapter != null) {
            rows.add(SectionLabel(e.chapter!, padding: const EdgeInsets.fromLTRB(8, 12, 8, 2)));
            last = e.chapter;
          }
          rows.add(fileRow(e.file));
        }
      case SideMode.tree:
        rows.addAll(_tree(visible.map((e) => e.file).toList(), fileRow, context));
    }

    return Material(
      color: c.sidebar,
      child: SizedBox(
        width: 300,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 18, 12, 6),
              child: SidebarBack(
                onPressed: () => goProject(context, review.project, const MrsPlace()),
                // The project first: the review page has no other place that says it.
                label: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: projectName,
                        style: context.t.bodyMedium!.copyWith(color: c.label, fontWeight: FontWeight.w600),
                      ),
                      const TextSpan(text: '  ·  Merge Requests'),
                    ],
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: SegmentedButton<SideMode>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: SideMode.chapters, label: Text('Chapters')),
                  ButtonSegment(value: SideMode.files, label: Text('Files')),
                  ButtonSegment(value: SideMode.tree, label: Text('Tree')),
                ],
                selected: {mode},
                onSelectionChanged: (s) => onMode(s.first),
              ),
            ),
            if (counts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final t in counts.keys.toList()..sort())
                      FilterChip(
                        label: Text('$t ${counts[t]}', style: context.t.bodyMedium!.copyWith(fontSize: 11)),
                        selected: hidden.contains(t),
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        tooltip: hidden.contains(t) ? 'Hidden: click to show' : 'Click to hide',
                        avatar: hidden.contains(t) ? const Icon(Icons.visibility_off_outlined, size: 12) : null,
                        onSelected: (on) => onTags(on ? [...hidden, t] : [...hidden.where((x) => x != t)]),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
              child: Text(hiddenFiles == 0 ? '${visible.length} files' : '${visible.length} files · $hiddenFiles hidden', style: context.t.bodySmall),
            ),
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(6, 0, 6, 12), children: rows),
            ),
          ],
        ),
      ),
    );
  }

  /// Folders fold into one row each; a chain of single folders reads as one.
  List<Widget> _tree(List<DiffFile> files, Widget Function(DiffFile, {double indent, String? label}) fileRow, BuildContext context) {
    final out = <Widget>[];
    void walk(String prefix, List<DiffFile> list, double indent) {
      final dirs = <String, List<DiffFile>>{};
      final here = <DiffFile>[];
      for (final f in list) {
        final rest = f.path.substring(prefix.length);
        final i = rest.indexOf('/');
        i < 0 ? here.add(f) : (dirs[rest.substring(0, i)] ??= []).add(f);
      }
      for (final MapEntry(key: name, value: sub) in (dirs.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))) {
        var label = name, path = '$prefix$name/';
        // Collapse a/b/c when each level holds only the next.
        while (true) {
          final next = {for (final f in sub) f.path.substring(path.length).split('/').first};
          if (next.length != 1 || sub.any((f) => !f.path.substring(path.length).contains('/'))) break;
          label = '$label/${next.first}';
          path = '$path${next.first}/';
        }
        out.add(
          Padding(
            padding: EdgeInsets.fromLTRB(8 + indent, 8, 8, 2),
            child: Row(
              children: [
                Icon(Icons.folder_outlined, size: 13, color: context.c.label2),
                const SizedBox(width: 5),
                Expanded(
                  child: Text('$label  ${sub.length}', overflow: TextOverflow.ellipsis, style: context.t.labelSmall),
                ),
              ],
            ),
          ),
        );
        walk(path, sub, indent + 12);
      }
      for (final f in here) {
        out.add(fileRow(f, indent: indent));
      }
    }

    walk('', files, 0);
    return out;
  }
}

class _ChapterHead extends StatelessWidget {
  const _ChapterHead({required this.review, required this.title});

  final Review review;
  final String title;

  @override
  Widget build(BuildContext context) {
    final g = review.groups.where((g) => g.title == title).firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: context.t.titleMedium?.copyWith(fontSize: 17)),
          if (g != null && g.overview.isNotEmpty) ...[
            const SizedBox(height: 3),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Text(g.overview, style: context.t.bodyMedium?.copyWith(color: context.c.label2)),
            ),
          ],
          if (title == 'Unclaimed') Text('Files no chapter claims.', style: context.t.bodySmall),
        ],
      ),
    );
  }
}

class _Features extends StatefulWidget {
  const _Features({required this.review, required this.project});

  final Review review;
  final String project;

  @override
  State<_Features> createState() => _FeaturesState();
}

class _FeaturesState extends State<_Features> {
  var _i = 0;

  @override
  Widget build(BuildContext context) {
    final fs = widget.review.features;
    final i = _i.clamp(0, fs.length - 1);
    final f = fs[i];
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('FEATURES', style: context.t.labelSmall),
          const SizedBox(height: 8),
          if (fs.length > 1)
            Wrap(
              spacing: 6,
              children: [
                for (final (j, x) in fs.indexed)
                  ChoiceChip(
                    label: Text(x.title),
                    selected: i == j,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _i = j),
                  ),
              ],
            )
          else
            Text(f.title, style: context.t.titleMedium),
          if (f.summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Text(f.summary, style: context.t.bodySmall),
            ),
          KeyedSubtree(
            key: ValueKey(i),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (f.graph != null && f.graph!.nodes.isNotEmpty) ClassGraphView(graph: f.graph!),
                if (f.graph != null && f.sequence != null) const SizedBox(height: 12),
                if (f.sequence != null) SequencePlayer(sequence: f.sequence!),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Overview extends ConsumerStatefulWidget {
  const _Overview({required this.review, required this.snap, required this.visible, required this.keyOf, required this.onFile});

  final Review review;
  final DiffSnapshot snap;
  final int visible;
  final ReviewKey keyOf;
  final ValueChanged<String> onFile;

  @override
  ConsumerState<_Overview> createState() => _OverviewState();
}

class _OverviewState extends ConsumerState<_Overview> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final r = widget.review, snap = widget.snap;
    final status = ref.watch(reviewStatusProvider(widget.keyOf)).value;
    final realAdd = snap.files.fold(0, (n, f) => n + f.realAdditions), realDel = snap.files.fold(0, (n, f) => n + f.realDeletions);
    final viewed = snap.files.where((f) => r.viewed[f.path] == snap.headSha).length;
    final description = r.mr?.description.trim() ?? '';

    Widget card(Widget child) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: ContentCard(
        padding: const EdgeInsets.all(14),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );

    Widget pathChips(List<String> paths) => Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final p in paths)
          ActionChip(
            label: Text(p.split('/').last, style: mono(context.t.bodyMedium!.copyWith(fontSize: 11))),
            visualDensity: VisualDensity.compact,
            tooltip: p,
            onPressed: () => widget.onFile(p),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 18,
            runSpacing: 6,
            children: [
              _Stat('${snap.files.length}', 'files'),
              _Stat('+$realAdd −$realDel', 'real lines'),
              _Stat('${snap.hiddenCount}', 'hidden as noise'),
              _Stat('$viewed/${snap.files.length}', 'viewed'),
              if (status != null)
                _Stat(
                  status.pipeline.isEmpty ? 'none' : status.pipeline,
                  'pipeline',
                  color: status.pipeline == 'failed' ? c.red : (status.pipeline == 'success' ? c.green : null),
                ),
            ],
          ),
          if (status != null && status.blockers.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Would not merge yet: ${status.blockers.join(', ')}.', style: context.t.bodySmall?.copyWith(color: c.orange)),
            ),
          if (r.groups.isNotEmpty) _WeightBar(review: r, snap: snap, onFile: widget.onFile),
          // All or nothing: its first lines are mostly a heading ("Summary").
          if (description.isNotEmpty && !_open)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: TextButton.icon(
                style: _compact,
                onPressed: () => setState(() => _open = true),
                icon: const Icon(Icons.expand_more_rounded, size: 16),
                label: const Text('Show the description'),
              ),
            )
          else if (description.isNotEmpty)
            card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  deckMarkdown(context, description),
                  TextButton(onPressed: () => setState(() => _open = false), child: const Text('Hide the description')),
                ],
              ),
            ),
          for (final t in r.ticketChecks)
            card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(t.ref, style: context.t.titleMedium),
                      const SizedBox(width: 8),
                      StatusTag(t.verdict.replaceAll('_', ' '), checkColor(c, t.verdict)),
                      if (t.headSha != snap.headSha) ...[const SizedBox(width: 6), StatusTag('older push', c.graphite)],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(t.summary, style: context.t.bodyMedium),
                  for (final it in t.items)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 64, child: StatusTag(it.state, checkColor(c, it.state))),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(it.text, style: context.t.bodyMedium),
                                if (it.paths.isNotEmpty) pathChips(it.paths),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          if (r.checklist.isNotEmpty)
            card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('TRIAGE', style: context.t.labelSmall),
                  for (final it in [...r.checklist.where((x) => x.state == 'concern'), ...r.checklist.where((x) => x.state != 'concern')])
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 64, child: StatusTag(it.state, checkColor(c, it.state))),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(it.text, style: context.t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                                if (it.evidence.isNotEmpty) Text(it.evidence, style: context.t.bodySmall),
                                if (it.paths.isNotEmpty) pathChips(it.paths),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One segment per chapter, as wide as its real lines. A click goes there.
class _WeightBar extends StatelessWidget {
  const _WeightBar({required this.review, required this.snap, required this.onFile});

  final Review review;
  final DiffSnapshot snap;
  final ValueChanged<String> onFile;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final byPath = {for (final f in snap.files) f.path: f};
    final palette = [c.blue, c.purple, c.teal, c.orange, c.indigo, c.green, c.red];
    final parts = [
      for (final g in review.groups)
        (g, g.items.map((i) => byPath[i.path]).whereType<DiffFile>().toSet().fold(0, (n, f) => n + f.realAdditions + f.realDeletions)),
    ].where((e) => e.$2 > 0).toList();
    if (parts.isEmpty) return const SizedBox();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: SizedBox(
          height: 22,
          child: Row(
            children: [
              for (final (i, (g, w)) in parts.indexed)
                Expanded(
                  flex: w,
                  child: Tooltip(
                    message: '${g.title}: $w lines',
                    child: InkWell(
                      onTap: g.items.isEmpty ? null : () => onFile(g.items.first.path),
                      child: Container(
                        color: palette[i % palette.length].withValues(alpha: .75),
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          g.title,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: context.t.bodySmall!.copyWith(fontSize: 11, color: context.c.onAccent, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.value, this.label, {this.color});

  final String value, label;
  final Color? color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      Text(
        value,
        style: context.t.titleMedium!.copyWith(fontSize: 15, fontWeight: FontWeight.w700, color: color ?? context.c.label),
      ),
      const SizedBox(width: 4),
      Text(label, style: context.t.bodySmall),
    ],
  );
}
