// The one step that leaves the machine. Nothing is posted until the reviewer
// has read the preview: what goes out, what is skipped and why, and the exact
// summary note. Port of Skim's Publish.tsx.
import 'package:flutter/material.dart';

import '../../core/review/review.dart';
import '../../core/review/publish_plan.dart';
import '../common.dart';
import '../theme.dart';
import 'thread_card.dart';

const _verdicts = [
  (value: 'comment', label: 'Comment', hint: 'Threads only, no verdict'),
  (value: 'approve', label: 'Approve', hint: 'Also approves the merge request'),
  (value: 'request_changes', label: 'Request changes', hint: 'Says so in the summary note'),
];

class PublishDialog extends StatefulWidget {
  const PublishDialog({
    super.key,
    required this.mr,
    required this.preview,
    required this.publish,
    this.own = false,
    this.onBrowser,
    this.summary = true,
    this.onSummary,
  });

  final MrSource mr;

  /// Opens the merge request in the browser, to read the thread there.
  final VoidCallback? onBrowser;

  /// Your own merge request: only your replies go out, no verdict, no summary.
  final bool own;
  final Future<PublishPreview> Function(String verdict, bool summary) preview;
  final Future<PublishResult> Function(String verdict, bool summary) publish;

  /// The summary note checkbox starts as you left it last time.
  final bool summary;
  final ValueChanged<bool>? onSummary;

  @override
  State<PublishDialog> createState() => _PublishDialogState();
}

class _PublishDialogState extends State<PublishDialog> {
  var _verdict = 'comment';
  late var _summary = !widget.own && widget.summary;
  var _source = false;
  late Future<PublishPreview> _preview = widget.preview(_verdict, _summary);
  PublishResult? _done;
  String? _error;
  var _busy = false;

  // A block body: an arrow would hand setState the Future, and it refuses that.
  void _reload() => setState(() {
    _preview = widget.preview(_verdict, _summary);
  });

  Future<void> _publish() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.publish(_verdict, _summary);
      if (mounted) setState(() => _done = r);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _plural(int n, String one, [String? many]) => '$n ${n == 1 ? one : many ?? '${one}s'}';

  @override
  Widget build(BuildContext context) {
    final c = context.c, t = context.t, mr = widget.mr, done = _done;
    final where = '${mr.projectPath} ${mr.provider == 'github' ? '#' : '!'}${mr.iid}';
    final browser = widget.onBrowser == null
        ? null
        : TextButton.icon(
            onPressed: widget.onBrowser,
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: Text(mr.provider == 'github' ? 'Open in GitHub' : 'Open in GitLab'),
          );
    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(done == null ? (widget.own ? 'Send your replies' : 'Publish review') : (widget.own ? 'Replies sent' : 'Round ${done.round.number} published')),
          Text(where, style: t.bodySmall),
        ],
      ),
      content: SizedBox(
        width: 640,
        child: done != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${_plural(done.published, 'discussion')} on $where.', style: t.bodyMedium),
                  if (done.replies > 0) Text('${_plural(done.replies, 'reply', 'replies')} on earlier threads.', style: t.bodyMedium),
                  if (done.skipped.isNotEmpty)
                    Text('${done.skipped.length} skipped, still accepted for the next round.', style: t.bodyMedium!.copyWith(color: c.orange)),
                ],
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!widget.own)
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SegmentedButton<String>(
                            showSelectedIcon: false,
                            segments: [for (final v in _verdicts) ButtonSegment(value: v.value, label: Text(v.label), tooltip: v.hint)],
                            selected: {_verdict},
                            onSelectionChanged: (s) {
                              _verdict = s.first;
                              _reload();
                            },
                          ),
                          Tooltip(
                            message: 'The round note under the merge request: chapters, file notes, counts. Off posts the threads only.',
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Checkbox(
                                  value: _summary,
                                  onChanged: (v) {
                                    _summary = v ?? true;
                                    widget.onSummary?.call(_summary);
                                    _reload();
                                  },
                                ),
                                Text('Summary note', style: t.bodyMedium),
                              ],
                            ),
                          ),
                        ],
                      ),
                    if (!_summary && _verdict == 'request_changes' && mr.provider == 'gitlab')
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'GitLab has no "changes requested" state: without the summary note, nothing on the merge request says so.',
                          style: t.bodySmall!.copyWith(color: c.orange),
                        ),
                      ),
                    const SizedBox(height: 12),
                    FutureBuilder(
                      future: _preview,
                      builder: (context, snap) {
                        if (snap.hasError) return Text('${snap.error}', style: t.bodySmall!.copyWith(color: c.red));
                        final p = snap.data;
                        if (p == null) return Text('Reading the diff…', style: t.bodySmall);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(text: 'Round ${p.roundNumber}: '),
                                  TextSpan(
                                    text: _plural(p.posting.length, 'new thread'),
                                    style: context.t.bodyMedium!.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  if (p.replies > 0) TextSpan(text: ', ${_plural(p.replies, 'reply', 'replies')}'),
                                  if (p.skipped.isNotEmpty)
                                    TextSpan(
                                      text: ', ${p.skipped.length} skipped',
                                      style: context.t.bodyMedium!.copyWith(color: c.red),
                                    ),
                                ],
                              ),
                              style: t.bodyMedium,
                            ),
                            if (p.pushes > 0)
                              Text(
                                'Pushes ${_plural(p.pushes, 'accepted fix', 'accepted fixes')} to ${mr.sourceBranch} first.',
                                style: t.bodySmall!.copyWith(color: c.blue),
                              ),
                            for (final s in p.skipped) Text('• ${s.reason}. It keeps its answer for the next round.', style: t.bodySmall),
                            const SizedBox(height: 6),
                            for (final th in p.posting)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Row(
                                  children: [
                                    SeverityBadge(th.severity),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(anchorLabel(th), overflow: TextOverflow.ellipsis, style: mono(t.bodySmall!.copyWith(fontSize: 11))),
                                    ),
                                  ],
                                ),
                              ),
                            if (p.summary case final summary?) ...[
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Text('SUMMARY NOTE', style: t.labelSmall),
                                  const SizedBox(width: 8),
                                  TextButton(onPressed: () => setState(() => _source = !_source), child: Text(_source ? 'Rendered' : 'Markdown source')),
                                ],
                              ),
                              Container(
                                width: double.infinity,
                                constraints: const BoxConstraints(maxHeight: 280),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(6)),
                                child: SingleChildScrollView(
                                  child: _source ? SelectableText(summary, style: mono(t.bodySmall!.copyWith(fontSize: 11))) : deckMarkdown(context, summary),
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_error!, style: t.bodySmall!.copyWith(color: c.red)),
                      ),
                  ],
                ),
              ),
      ),
      actions: done != null
          ? [?browser, FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))]
          : [
              ?browser,
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FutureBuilder(
                future: _preview,
                builder: (context, snap) => FilledButton(
                  // Nothing to send is not a publish.
                  onPressed:
                      _busy ||
                          snap.data == null ||
                          (snap.data!.posting.isEmpty &&
                              snap.data!.replies == 0 &&
                              snap.data!.pushes == 0 &&
                              snap.data!.summary == null &&
                              _verdict != 'approve')
                      ? null
                      : _publish,
                  child: Text(_busy ? 'Publishing…' : 'Publish to $where'),
                ),
              ),
            ],
    );
  }
}
