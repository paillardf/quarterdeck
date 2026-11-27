// One file of a review diff, drawn natively: a header that pins while its
// lines scroll, hunks with fold headers, moved lines dimmed, small edits
// collapsed onto one row (core/review/unified.dart), word edits marked, syntax
// colors from re_highlight, and context expansion between hunks.
//
// FileDiffView is a SLIVER. Put one per file straight in
// CustomScrollView.slivers: rows are built lazily by a SliverList, so a
// 3,000 line diff costs only the rows on screen, and each file's header sticks
// to the top while its lines pass under it.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/gradle.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../core/review/diff.dart';
import '../../core/review/unified.dart';
import '../parts.dart';
import '../theme.dart';
import '../theme.dart' as theme show mono;

/// Past this many changed lines the file waits for a click before rendering.
const largeDiffLines = 800;

/// Long enough that a reviewer wants to know what is in it before reading it.
const longHunkLines = 25;

/// Lines one click on an expand arrow reveals.
const expandStep = 20;

class FileDiffView extends StatefulWidget {
  const FileDiffView({
    super.key,
    required this.file,
    this.hunkNotes = const {},
    this.split = false,
    this.note,
    this.viewed = false,
    this.onViewed,
    this.loadContext,
    this.onOpen,
    this.below = const {},
    this.onLine,
    this.selected,
    this.reveal,
  });

  final DiffFile file;

  /// One line per hunk ref. A hunk with a note, or a long one, gets a fold header.
  final Map<String, String> hunkNotes;

  /// Old and new side by side instead of one column.
  final bool split;

  /// The file's one line summary, under the path.
  final String? note;
  final bool viewed;
  final ValueChanged<bool>? onViewed;

  /// New side lines [fromLine, toLine], 1 based. Null hides the expand controls.
  final Future<List<String>?> Function(int fromLine, int toLine)? loadContext;

  /// Opens the file at a new side line, from a line number or the header.
  final void Function(int line)? onOpen;

  /// Rows shown under a diff line, keyed by side (new or old) and line
  /// number: the threads anchored there, the form of a new one.
  final Map<(String, int), List<Widget>> below;

  /// A click on the sign column of a diff line; [extend] with shift held, to
  /// make a range.
  final void Function(String side, int line, {bool extend})? onLine;

  /// The lines picked for a new thread, tinted.
  final ({String side, int from, int to})? selected;

  /// A thread card to show, [card] its key, under a line: the file opens,
  /// the hunk unfolds, a large diff loads, and the page jumps to the card.
  /// A new [seq] does it again.
  final ({String side, int line, Key card, int seq})? reveal;

  @override
  State<FileDiffView> createState() => _FileDiffViewState();
}

// ---- rows -----------------------------------------------------------------

sealed class _Item {}

class _Note extends _Item {
  _Note(this.text, [this.action, this.onAction]);
  final String text;
  final String? action;
  final VoidCallback? onAction;
}

class _Gap extends _Item {
  _Gap(this.gap, this.hidden, this.header, {required this.up, required this.down});

  /// Hidden lines, null after the last hunk where the file length is unknown.
  final int gap;
  final int? hidden;
  final String header;
  final bool up, down;
}

class _Fold extends _Item {
  _Fold(this.hunk, this.lines, this.note, this.folded);
  final int hunk, lines;
  final String? note;
  final bool folded;
}

class _URow extends _Item {
  _URow(this.row, this.hunk);
  final UnifiedRow row;
  final int hunk;
}

class _SRow extends _Item {
  _SRow(this.row, this.hunk);
  final SplitRow row;
  final int hunk;
}

/// A context line revealed by an expand click.
class _Ctx extends _Item {
  _Ctx(this.oldLine, this.newLine, this.text);
  final int oldLine, newLine;
  final String text;
}

/// A row the parent gave, under its line.
class _Below extends _Item {
  _Below(this.child);
  final Widget child;
}

class _GapState {
  final top = <String>[], bottom = <String>[];
  bool end = false, busy = false;
}

/// A colored stretch of one line: [start, end) and its highlight.js scope.
typedef _Tok = (int, int, String);
typedef _SideToks = ({Map<int, List<_Tok>> old, Map<int, List<_Tok>> neu});

class _FileDiffViewState extends State<FileDiffView> {
  late bool _collapsed = widget.viewed;
  bool _forceLarge = false;
  final _folded = <int>{};
  final _gaps = <int, _GapState>{};
  final _rows = <(int, bool), List<_Item>>{};
  final _toks = <int, _SideToks>{};
  final _ctxToks = <int, List<_Tok>>{};
  final _edits = Expando<List<(int, int)>>();
  List<_Item>? _items;

  @override
  void initState() {
    super.initState();
    _open(widget.reveal);
  }

  final _list = ListController();

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  /// Opens what hides [r]'s line (the file folded as viewed, its hunk
  /// folded, a large diff not loaded), then once its rows are built, jumps
  /// to its card, or to the line when the card is not there.
  void _open(({String side, int line, Key card, int seq})? r) {
    if (r == null) return;
    _collapsed = false;
    _forceLarge = true;
    for (final (i, h) in widget.file.hunks.indexed) {
      if (h.lines.any((l) => (r.side == 'old' ? l.oldLine : l.newLine) == r.line)) _folded.remove(i);
    }
    _items = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final items = _items, scroll = mounted ? Scrollable.maybeOf(context)?.widget.controller : null;
      if (items == null || scroll == null || !_list.isAttached) return;
      var i = items.indexWhere((it) => it is _Below && it.child.key == r.card);
      if (i < 0) i = items.indexWhere((it) => _keysOf(it).contains((r.side, r.line)));
      if (i >= 0) _list.jumpToItem(index: i, scrollController: scroll, alignment: .15);
    });
  }

  @override
  void didUpdateWidget(FileDiffView old) {
    super.didUpdateWidget(old);
    if (old.viewed != widget.viewed) _collapsed = widget.viewed;
    if (old.file != widget.file) {
      _folded.clear();
      _gaps.clear();
      _rows.clear();
      _toks.clear();
      _ctxToks.clear();
      _forceLarge = false;
    }
    if (old.file != widget.file ||
        old.split != widget.split ||
        old.hunkNotes != widget.hunkNotes ||
        old.loadContext != widget.loadContext ||
        old.below != widget.below ||
        old.selected != widget.selected) {
      _items = null;
    }
    if (old.reveal != widget.reveal) _open(widget.reveal);
  }

  void _change(VoidCallback f) => setState(() {
    f();
    _items = null;
  });

  // ---- what rows the file has ----

  /// A hunk's new side span, first and last line. A pure deletion has none:
  /// git then names the line before it.
  (int, int) _span(Hunk h) {
    final a = h.newCount == 0 ? h.newStart + 1 : h.newStart;
    return (a, a + h.newCount - 1);
  }

  /// New side lines hidden before hunk [g] (or after the last when g == hunks),
  /// and what to add to a new line number to get the old one.
  ({int from, int? to, int delta}) _gapSpan(int g) {
    final hunks = widget.file.hunks;
    int oldA(Hunk h) => h.oldCount == 0 ? h.oldStart + 1 : h.oldStart;
    if (g == hunks.length) {
      final h = hunks.last;
      return (from: _span(h).$2 + 1, to: null, delta: oldA(h) - _span(h).$1 + h.oldCount - h.newCount);
    }
    final h = hunks[g];
    return (from: g == 0 ? 1 : _span(hunks[g - 1]).$2 + 1, to: _span(h).$1 - 1, delta: oldA(h) - _span(h).$1);
  }

  List<_Item> _build() {
    final f = widget.file;
    if (f.isBinary) return [_Note('Binary file, not shown.')];
    if (f.hunks.isEmpty) return [_Note(f.status == 'renamed' ? 'Renamed, content unchanged.' : 'No line changes.')];
    final total = f.additions + f.deletions;
    if (total > largeDiffLines && !_forceLarge) return [_Note('Large diff, $total lines.', 'Load diff', () => _change(() => _forceLarge = true))];
    final out = <_Item>[];
    // Split hunks can share a context line: what goes below it is placed once.
    final placed = <(String, int)>{};
    for (var i = 0; i <= f.hunks.length; i++) {
      _addGap(out, i);
      if (i == f.hunks.length) break;
      final h = f.hunks[i];
      final note = widget.hunkNotes[h.ref];
      final foldable = note != null || h.lines.length >= longHunkLines;
      final folded = foldable && _folded.contains(i);
      if (foldable) out.add(_Fold(i, h.lines.length, note, folded));
      if (folded) continue;
      final rows = _rows[(i, widget.split)] ??= widget.split
          ? [for (final r in pairSplit(h.lines)) _SRow(r, i)]
          : [for (final r in regroupUnified(h.lines)) _URow(r, i)];
      if (widget.below.isEmpty) {
        out.addAll(rows);
        continue;
      }
      for (final r in rows) {
        out.add(r);
        for (final k in _keysOf(r)) {
          if (!placed.add(k)) continue;
          for (final w in widget.below[k] ?? const <Widget>[]) {
            out.add(_Below(w));
          }
        }
      }
    }
    return out;
  }

  /// The (side, line) keys a diff row answers to.
  List<(String, int)> _keysOf(_Item r) {
    final (int? o, int? n) = switch (r) {
      _URow(:final row) => (row.oldLine, row.newLine),
      _SRow(:final row) => (row.old?.oldLine, row.neu?.newLine),
      _ => (null, null),
    };
    return [if (n != null) ('new', n), if (o != null) ('old', o)];
  }

  bool _picked(String side, int? line) {
    final s = widget.selected;
    return s != null && line != null && s.side == side && s.from <= line && line <= s.to;
  }

  void _addGap(List<_Item> out, int g) {
    final f = widget.file;
    final canExpand = widget.loadContext != null && f.status != 'deleted' && f.status != 'added';
    final (:from, :to, :delta) = _gapSpan(g);
    final s = _gaps[g];
    final header = g < f.hunks.length ? f.hunks[g].header : '';
    if (to == null) {
      // After the last hunk: only worth a row when it can grow.
      if (!canExpand) return;
      for (final (k, t) in (s?.top ?? const <String>[]).indexed) {
        out.add(_Ctx(from + k + delta, from + k, t));
      }
      if (!(s?.end ?? false)) out.add(_Gap(g, null, '', up: false, down: true));
      return;
    }
    final hidden = to - from + 1;
    if (hidden <= 0) return;
    final top = s?.top ?? const <String>[], bottom = s?.bottom ?? const <String>[];
    for (final (k, t) in top.indexed) {
      out.add(_Ctx(from + k + delta, from + k, t));
    }
    final left = hidden - top.length - bottom.length;
    if (left > 0) out.add(_Gap(g, left, header, up: canExpand && g < f.hunks.length, down: canExpand && g > 0));
    for (final (k, t) in bottom.indexed) {
      final n = to - bottom.length + 1 + k;
      out.add(_Ctx(n + delta, n, t));
    }
  }

  Future<void> _expand(int g, {required bool down, bool all = false}) async {
    final s = _gaps[g] ??= _GapState();
    if (s.busy) return;
    final (:from, :to, delta: _) = _gapSpan(g);
    final lo = from + s.top.length, hi = to == null ? null : to - s.bottom.length;
    if (hi != null && hi < lo) return;
    final (a, b) = all
        ? (lo, hi!)
        : down
        ? (lo, hi == null ? lo + expandStep - 1 : math.min(hi, lo + expandStep - 1))
        : (math.max(lo, hi! - expandStep + 1), hi);
    s.busy = true;
    final lines = await widget.loadContext!(a, b);
    if (!mounted) return;
    _change(() {
      s.busy = false;
      if (lines == null) return;
      final want = b - a + 1;
      final got = lines.length > want ? lines.sublist(0, want) : lines;
      if (down || all) {
        s.top.addAll(got);
        // Fewer lines than asked after the last hunk: that is the end of the file.
        if (to == null && got.length < want) s.end = true;
      } else {
        s.bottom.insertAll(0, got);
      }
    });
  }

  // ---- highlight and edits ----

  _SideToks _hunkToks(int i) => _toks[i] ??= () {
    final lang = _languageFor(widget.file.path);
    final lines = widget.file.hunks[i].lines;
    final olds = [
          for (final l in lines)
            if (l.oldLine != null) l,
        ],
        news = [
          for (final l in lines)
            if (l.newLine != null) l,
        ];
    List<List<_Tok>> run(List<DiffLine> side) => _highlight(lang, side.map((l) => l.content).join('\n'), side.length);
    final o = run(olds), n = run(news);
    return (old: {for (final (k, l) in olds.indexed) l.oldLine!: o[k]}, neu: {for (final (k, l) in news.indexed) l.newLine!: n[k]});
  }();

  List<_Tok> _toksOf(DiffLine l, int hunk) {
    final t = _hunkToks(hunk);
    return (l.newLine != null ? t.neu[l.newLine] : t.old[l.oldLine]) ?? const [];
  }

  /// Changed characters of [l] against its pair, computed once per line.
  List<(int, int)> _editsOf(DiffLine l, DiffLine partner) => _edits[l] ??= () {
    final e = l.type == lineAdd ? lineEdits(partner.content, l.content) : lineEdits(l.content, partner.content);
    return l.type == lineAdd ? e.neu : e.old;
  }();

  // ---- widgets ----

  /// Width of the line number columns, from the biggest number shown (expanded context included).
  int get _digits {
    var most = 0;
    for (final h in widget.file.hunks) {
      most = math.max(most, math.max(h.oldStart + h.oldCount, h.newStart + h.newCount));
    }
    for (final s in _gaps.values) {
      most += s.top.length;
    }
    return math.max(3, '$most'.length);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final st = _Styles.of(context, _digits);
    final items = _collapsed ? const <_Item>[] : (_items ??= _build());
    final radius = BorderRadius.circular(8);
    return SliverPadding(
      padding: const EdgeInsets.only(bottom: 12),
      sliver: DecoratedSliver(
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: radius,
          border: Border.all(color: c.sep),
        ),
        sliver: SliverMainAxisGroup(
          slivers: [
            PinnedHeaderSliver(child: _header(context, st)),
            if (items.isNotEmpty) ...[
              SuperSliverList.builder(
                listController: _list,
                itemCount: items.length,
                extentEstimation: (i, _) => switch (i == null ? null : items[i]) {
                  _Below() => 160,
                  _Fold() || _Gap() || _Note() => 26,
                  _ => 18,
                },
                itemBuilder: (context, i) => _row(context, st, items[i]),
                // A thread card keeps its state (an open reply box) when rows above it come and go.
                findChildIndexCallback: (key) {
                  final i = items.indexWhere((it) => it is _Below && it.child.key == key);
                  return i < 0 ? null : i;
                },
              ),
              // Keeps the last row off the rounded corners.
              const SliverToBoxAdapter(child: SizedBox(height: 6)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, _Styles st) {
    final c = context.c, t = context.t, f = widget.file;
    final moved = f.additions + f.deletions - f.realAdditions - f.realDeletions;
    final small = t.labelSmall!;
    final firstLine = f.hunks.expand((h) => h.lines).map((l) => l.newLine).whereType<int>().firstOrNull ?? 1;
    return Material(
      color: st.headerBg,
      shape: RoundedRectangleBorder(
        borderRadius: _collapsed ? BorderRadius.circular(7.5) : const BorderRadius.vertical(top: Radius.circular(7.5)),
        side: BorderSide.none,
      ),
      child: InkWell(
        onTap: () => _change(() => _collapsed = !_collapsed),
        child: Container(
          decoration: _collapsed
              ? null
              : BoxDecoration(
                  border: Border(bottom: BorderSide(color: c.sep, width: .5)),
                ),
          padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_collapsed ? Icons.chevron_right : Icons.expand_more, size: 18, color: c.label2),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                if (f.oldPath != f.newPath)
                                  TextSpan(
                                    text: '${f.oldPath} → ',
                                    style: TextStyle(color: c.label2),
                                  ),
                                TextSpan(text: f.path),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: st.mono.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.3),
                          ),
                        ),
                        if (f.status != 'modified') _chip(context, f.status, _statusColor(c, f.status)),
                        for (final tag in f.tags) _chip(context, tag, c.graphite),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (f.hunks.isNotEmpty)
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '+${f.realAdditions}',
                            style: TextStyle(color: st.addInk),
                          ),
                          const TextSpan(text: ' '),
                          TextSpan(
                            text: '-${f.realDeletions}',
                            style: TextStyle(color: st.delInk),
                          ),
                          if (moved > 0)
                            TextSpan(
                              text: ' · $moved moved',
                              style: TextStyle(color: c.label2),
                            ),
                        ],
                      ),
                      style: st.mono.copyWith(fontSize: 11.5, height: 1.3),
                    ),
                  if (widget.onOpen != null) ...[
                    const SizedBox(width: 6),
                    _iconButton(context, Icons.open_in_new, 'Open in IDE', () => widget.onOpen!(firstLine)),
                  ],
                  if (widget.onViewed != null) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: Checkbox(
                        value: widget.viewed,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: (v) => widget.onViewed!(v ?? false),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text('Viewed', style: small.copyWith(fontWeight: FontWeight.w500)),
                  ],
                ],
              ),
              if (widget.note case final note? when note.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 22, top: 2),
                  child: Text(note, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.bodySmall),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Color _statusColor(DeckColors c, String status) => switch (status) {
    'added' => c.green,
    'deleted' => c.red,
    'renamed' || 'copied' => c.blue,
    _ => c.graphite,
  };

  Widget _chip(BuildContext context, String text, Color color) => Padding(padding: const EdgeInsets.only(left: 6), child: StatusTag(text, color));

  Widget _iconButton(BuildContext context, IconData icon, String tip, VoidCallback onTap) => Tooltip(
    message: tip,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Icon(icon, size: 14, color: context.c.label2),
      ),
    ),
  );

  Widget _row(BuildContext context, _Styles st, _Item item) => switch (item) {
    _Note(:final text, :final action, :final onAction) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(text, style: context.t.bodySmall),
          if (action != null) ...[const SizedBox(width: 10), OutlinedButton(onPressed: onAction, child: Text(action))],
        ],
      ),
    ),
    _Below(:final child) => Padding(key: child.key, padding: const EdgeInsets.fromLTRB(12, 4, 12, 6), child: child),
    _Gap() => _gapRow(context, st, item),
    _Fold() => _foldRow(context, st, item),
    _URow(:final row, :final hunk) => _unifiedRow(context, st, row, hunk),
    _SRow(:final row, :final hunk) => _splitRow(context, st, row, hunk),
    _Ctx(:final oldLine, :final newLine, :final text) =>
      widget.split
          ? _pairOfHalves(
              st,
              _half(context, st, oldLine, ' ', _code(st, text, _ctxToksOf(newLine, text)), null, open: false),
              _half(context, st, newLine, ' ', _code(st, text, _ctxToksOf(newLine, text)), null),
            )
          : _line(context, st, oldLine, newLine, ' ', _code(st, text, _ctxToksOf(newLine, text)), null),
  };

  List<_Tok> _ctxToksOf(int line, String text) => _ctxToks[line] ??= _highlight(_languageFor(widget.file.path), text, 1).first;

  Widget _gapRow(BuildContext context, _Styles st, _Gap g) {
    final busy = _gaps[g.gap]?.busy ?? false;
    final small = g.hidden != null && g.hidden! <= expandStep;
    return Material(
      color: st.gapBg,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: st.gutterWidth(widget.split),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: busy
                    ? [const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))]
                    : small && (g.up || g.down)
                    ? [_iconButton(context, Icons.unfold_more, 'Show ${g.hidden} lines', () => _expand(g.gap, down: true, all: true))]
                    : [
                        if (g.down) _iconButton(context, Icons.keyboard_arrow_down, 'Show $expandStep lines below', () => _expand(g.gap, down: true)),
                        if (g.up) _iconButton(context, Icons.keyboard_arrow_up, 'Show $expandStep lines above', () => _expand(g.gap, down: false)),
                      ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: g.hidden == null ? 'more below' : '${g.hidden} hidden line${g.hidden == 1 ? '' : 's'}'),
                    if (g.header.isNotEmpty)
                      TextSpan(
                        text: '   ${g.header}',
                        style: TextStyle(color: context.c.label),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: st.mono.copyWith(color: context.c.label2, fontSize: 11.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _foldRow(BuildContext context, _Styles st, _Fold f) {
    final c = context.c;
    return Material(
      color: st.foldBg,
      child: InkWell(
        onTap: () => _change(() => f.folded ? _folded.remove(f.hunk) : _folded.add(f.hunk)),
        child: Container(
          decoration: BoxDecoration(
            border: Border.symmetric(horizontal: BorderSide(color: c.sep, width: .5)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(f.folded ? Icons.chevron_right : Icons.expand_more, size: 16, color: c.label2),
              const SizedBox(width: 4),
              Text('${f.lines} lines', style: st.mono.copyWith(fontSize: 11.5, color: c.label2)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  f.note ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.t.bodySmall!.copyWith(color: c.label),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _unifiedRow(BuildContext context, _Styles st, UnifiedRow r, int hunk) {
    final l = r.line, moved = l.moved;
    final (sign, bg, edit) = switch (r.kind) {
      RowKind.context => (' ', null, null),
      RowKind.add => ('+', moved ? st.movedBg : st.addBg, st.addEdit),
      RowKind.delete => ('-', moved ? st.movedBg : st.delBg, st.delEdit),
      RowKind.tweak => (' ', st.tweakBg, st.addEdit),
    };
    final edits = r.partner != null && !moved ? _editsOf(l, r.partner!) : const <(int, int)>[];
    final side = r.kind == RowKind.delete ? 'old' : 'new';
    final at = side == 'old' ? r.oldLine : r.newLine;
    final row = _line(
      context,
      st,
      r.oldLine,
      r.newLine,
      sign,
      _code(st, l.content, _toksOf(l, hunk), edits: edits, editBg: edit, dim: moved),
      _picked(side, at) ? st.pickBg : bg,
      pick: at == null ? null : (side, at),
    );
    final was = r.was;
    if (was == null) return row;
    // The hover names what the collapsed row replaced.
    final same = was.content.trim() == l.content.trim();
    return Tooltip(message: same ? 'indentation changed' : 'was: ${was.content.trim()}', waitDuration: const Duration(milliseconds: 300), child: row);
  }

  Widget _splitRow(BuildContext context, _Styles st, SplitRow r, int hunk) {
    Widget side(DiffLine? l, DiffLine? partner, {required bool old}) {
      if (l == null) return ColoredBox(color: st.emptyBg, child: const SizedBox.expand());
      final ctx = l.type == lineContext;
      final bg = ctx ? null : (l.moved ? st.movedBg : (old ? st.delBg : st.addBg));
      final edits = r.similar && partner != null && !l.moved ? _editsOf(l, partner) : const <(int, int)>[];
      final n = old ? l.oldLine : l.newLine;
      final code = _code(st, l.content, _toksOf(l, hunk), edits: edits, editBg: old ? st.delEdit : st.addEdit, dim: l.moved);
      final side = old ? 'old' : 'new';
      return _half(context, st, n, ctx ? ' ' : (old ? '-' : '+'), code, _picked(side, n) ? st.pickBg : bg, open: !old, pick: n == null ? null : (side, n));
    }

    return _pairOfHalves(st, side(r.old, r.neu, old: true), side(r.neu, r.old, old: false));
  }

  Widget _pairOfHalves(_Styles st, Widget left, Widget right) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: left),
        Container(width: .5, color: st.sep),
        Expanded(child: right),
      ],
    ),
  );

  /// One unified line: old number, new number, sign, code.
  Widget _line(BuildContext context, _Styles st, int? oldLine, int? newLine, String sign, InlineSpan code, Color? bg, {(String, int)? pick}) => Container(
    color: bg,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _num(st, oldLine, open: false),
        _num(st, newLine),
        _sign(st, sign, pick),
        Expanded(child: _text(st, code)),
      ],
    ),
  );

  /// One side of a split line.
  Widget _half(BuildContext context, _Styles st, int? line, String sign, InlineSpan code, Color? bg, {bool open = true, (String, int)? pick}) => Container(
    color: bg,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _num(st, line, open: open),
        _sign(st, sign, pick),
        Expanded(child: _text(st, code)),
      ],
    ),
  );

  Widget _num(_Styles st, int? n, {bool open = true}) {
    final label = Container(
      width: st.numWidth,
      padding: const EdgeInsets.only(right: 6, top: 1),
      alignment: Alignment.topRight,
      child: Text(n?.toString() ?? '', style: st.number, strutStyle: st.strut),
    );
    if (n == null || !open || widget.onOpen == null) return label;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: () => widget.onOpen!(n), child: label),
    );
  }

  /// The sign column. With [pick] and [FileDiffView.onLine] a click there
  /// starts a thread on that line, shift extends it to a range.
  Widget _sign(_Styles st, String sign, [(String, int)? pick]) {
    final cell = SizedBox(
      width: 14,
      child: Padding(
        padding: const EdgeInsets.only(top: 1),
        child: Text(sign, style: st.number, strutStyle: st.strut),
      ),
    );
    final on = widget.onLine;
    if (pick == null || on == null) return cell;
    return Tooltip(
      message: 'Comment (shift for a range)',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => on(pick.$1, pick.$2, extend: HardwareKeyboard.instance.isShiftPressed),
          child: cell,
        ),
      ),
    );
  }

  Widget _text(_Styles st, InlineSpan code) => Padding(
    padding: const EdgeInsets.only(top: 1, bottom: 1, right: 8),
    child: Text.rich(code, style: st.mono, strutStyle: st.strut),
  );

  /// The code of one line: syntax colors, with the edited stretches on a stronger tint.
  InlineSpan _code(_Styles st, String text, List<_Tok> toks, {List<(int, int)> edits = const [], Color? editBg, bool dim = false}) {
    if (text.isEmpty) return const TextSpan(text: '');
    final cuts = <int>{
      0,
      text.length,
      for (final (a, b, _) in toks) ...[a, b],
      for (final (a, b) in edits) ...[a, b],
    }.toList()..sort();
    final spans = <TextSpan>[];
    var ti = 0;
    for (var k = 0; k + 1 < cuts.length; k++) {
      final a = cuts[k], b = cuts[k + 1];
      if (a >= b || a >= text.length) continue;
      while (ti < toks.length && toks[ti].$2 <= a) {
        ti++;
      }
      final scope = ti < toks.length && toks[ti].$1 <= a ? toks[ti].$3 : null;
      final edited = edits.any((e) => e.$1 <= a && b <= e.$2);
      final style = dim ? TextStyle(color: st.dimInk) : st.scope(scope);
      spans.add(
        TextSpan(
          // Tabs draw as a box or nothing in a Text: four spaces read the same.
          text: text.substring(a, b).replaceAll('\t', '    '),
          style: edited && editBg != null ? (style ?? const TextStyle()).copyWith(backgroundColor: editBg) : style,
        ),
      );
    }
    return TextSpan(children: spans);
  }
}

// ---- colors ----------------------------------------------------------------

/// Every color and text style of the diff, derived from Deck's palette.
class _Styles {
  _Styles._(this.c, this.dark, this.mono, this.digits);

  factory _Styles.of(BuildContext context, int digits) {
    final c = context.c;
    final code = theme.mono(context.t.bodySmall!.copyWith(fontSize: 12, height: 1.5, color: c.label, letterSpacing: 0));
    return _Styles._(c, Theme.of(context).brightness == Brightness.dark, code, digits);
  }

  final DeckColors c;
  final bool dark;
  final TextStyle mono;
  final int digits;

  StrutStyle get strut => StrutStyle(fontFamily: 'Menlo', fontFamilyFallback: mono.fontFamilyFallback, fontSize: 12, height: 1.5, forceStrutHeight: true);
  TextStyle get number => mono.copyWith(color: c.label3, fontSize: 11);
  double get numWidth => digits * 7.0 + 12;
  double gutterWidth(bool split) => split ? numWidth + 14 : numWidth * 2 + 14;

  Color get sep => c.sep;
  // c.fill is already a translucent grey: scale its alpha, withValues would replace it.
  Color _fill(double k) => c.fill.withValues(alpha: c.fill.a * k);
  Color get headerBg => Color.alphaBlend(_fill(dark ? 1.2 : .9), c.card);
  Color get addBg => c.green.withValues(alpha: dark ? .13 : .11);
  Color get delBg => c.red.withValues(alpha: dark ? .13 : .08);
  Color get addEdit => c.green.withValues(alpha: dark ? .32 : .30);
  Color get delEdit => c.red.withValues(alpha: dark ? .32 : .22);
  Color get tweakBg => c.green.withValues(alpha: dark ? .06 : .045);
  Color get movedBg => _fill(dark ? .9 : 1.1);
  Color get emptyBg => _fill(.5);
  Color get gapBg => c.blue.withValues(alpha: dark ? .08 : .05);
  Color get foldBg => _fill(dark ? .8 : .7);
  Color get pickBg => c.blue.withValues(alpha: dark ? .22 : .16);
  Color get dimInk => c.label2;
  Color get addInk => _ink(c.green);
  Color get delInk => _ink(c.red);

  /// A Deck tint made readable as text: darker on light cards, a touch lighter on dark ones.
  Color _ink(Color tint) => dark ? Color.lerp(tint, c.label, .2)! : Color.lerp(tint, Colors.black, .38)!;

  late final _byScope = <String, TextStyle>{
    'keyword': TextStyle(color: _ink(c.purple)),
    'string': TextStyle(color: _ink(c.orange)),
    'number': TextStyle(color: _ink(c.indigo)),
    'type': TextStyle(color: _ink(c.teal)),
    'function': TextStyle(color: _ink(c.blue)),
    'comment': TextStyle(color: c.label2, fontStyle: FontStyle.italic),
    'meta': TextStyle(color: _ink(c.graphite)),
  };

  /// highlight.js scopes folded onto the handful of colors above.
  TextStyle? scope(String? s) {
    if (s == null) return null;
    final head = s.split('.').first;
    return _byScope[switch (head) {
      'keyword' || 'selector-tag' || 'doctag' || 'tag' => 'keyword',
      'string' || 'regexp' || 'char' || 'symbol' || 'link' => 'string',
      'number' || 'literal' => 'number',
      'built_in' || 'type' || 'class' || 'attr' || 'attribute' || 'property' || 'name' => 'type',
      'title' => s.startsWith('title.function') ? 'function' : 'type',
      'function' => 'function',
      'comment' || 'quote' || 'doc' => 'comment',
      'meta' || 'annotation' || 'section' || 'bullet' => 'meta',
      _ => '',
    }];
  }
}

// ---- syntax ----------------------------------------------------------------

final _hl = Highlight();
final _registered = <String>{};

/// Grammars by name. The language files are big (swift is 380 KB of source),
/// so each is built on first use: a top level final only runs when read.
final _grammars = <String, Mode Function()>{
  'bash': () => langBash,
  'css': () => langCss,
  'dart': () => langDart,
  'go': () => langGo,
  'gradle': () => langGradle,
  'java': () => langJava,
  'javascript': () => langJavascript,
  'json': () => langJson,
  'kotlin': () => langKotlin,
  'markdown': () => langMarkdown,
  'python': () => langPython,
  'ruby': () => langRuby,
  'rust': () => langRust,
  'swift': () => langSwift,
  'typescript': () => langTypescript,
  'xml': () => langXml,
  'yaml': () => langYaml,
};

const _byExt = {
  'dart': 'dart',
  'ts': 'typescript',
  'tsx': 'typescript',
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'swift': 'swift',
  'py': 'python',
  'json': 'json',
  'yaml': 'yaml',
  'yml': 'yaml',
  'md': 'markdown',
  'css': 'css',
  'html': 'xml',
  'xml': 'xml',
  'sh': 'bash',
  'go': 'go',
  'rs': 'rust',
  'java': 'java',
  'gradle': 'gradle',
  'rb': 'ruby',
};

String? _languageFor(String path) {
  final dot = path.lastIndexOf('.');
  return dot < 0 ? null : _byExt[path.substring(dot + 1).toLowerCase()];
}

/// Colored stretches of each of [lines] lines of [code], or none when the
/// language is unknown or the grammar throws.
List<List<_Tok>> _highlight(String? lang, String code, int lines) {
  final out = List.generate(lines, (_) => <_Tok>[]);
  if (lang == null || lines == 0) return out;
  try {
    if (_registered.add(lang)) _hl.registerLanguage(lang, _grammars[lang]!());
    final r = _Runs(out);
    _hl.highlight(code: code, language: lang).render(r);
  } catch (_) {
    for (final l in out) {
      l.clear();
    }
  }
  return out;
}

/// Flattens re_highlight's token tree to per line stretches, innermost scope wins.
class _Runs implements HighlightRenderer {
  _Runs(this.out);
  final List<List<_Tok>> out;
  final _scopes = <String?>[];
  var _line = 0, _col = 0;

  @override
  void addText(String text) {
    final scope = _scopes.lastWhere((s) => s != null && !s.startsWith('language:'), orElse: () => null);
    final parts = text.split('\n');
    for (var k = 0; k < parts.length; k++) {
      if (k > 0) {
        _line++;
        _col = 0;
      }
      final p = parts[k];
      if (scope != null && p.isNotEmpty && _line < out.length) out[_line].add((_col, _col + p.length, scope));
      _col += p.length;
    }
  }

  @override
  void openNode(DataNode node) => _scopes.add(node.scope);

  @override
  void closeNode(DataNode node) {
    if (_scopes.isNotEmpty) _scopes.removeLast();
  }
}
