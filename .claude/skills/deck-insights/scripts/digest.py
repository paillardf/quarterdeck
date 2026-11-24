#!/usr/bin/env python3
"""Digest of the Claude sessions Deck ran: what fails, what is slow, what costs.

Reads, for the last N days:
  - the run ledger      <deck>/cache/runs/YYYY-MM.jsonl  (one line per run)
  - reported issues     <deck>/cache/runs/issues.jsonl   (deck_report_issue)
  - the transcripts     ~/.claude/projects/<dir>/<session>.jsonl
    (worker transcripts are read even without a ledger line, so the runs from
    before the ledger count too)

Prints one JSON object. Saves it to <deck>/cache/insights/<date>.json and adds
"previous": the totals of the last saved digest, for the trend.

Usage: digest.py [--days 7] [--deck ~/.deck] [--no-save]
"""
import argparse
import glob
import json
import os
import re
import statistics
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

HOME = os.path.expanduser('~')
PROJECTS = os.path.join(os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(HOME, '.claude'), 'projects')


def deck_home(arg):
    if arg:
        return os.path.expanduser(arg)
    if os.environ.get('DECK_HOME'):
        return os.path.expanduser(os.environ['DECK_HOME'])
    pointer = os.path.join(HOME, '.deck', 'home')
    if os.path.exists(pointer):
        saved = open(pointer).read().strip()
        if saved:
            return os.path.expanduser(saved)
    return os.path.join(HOME, '.deck')


def transcript_dir(folder):
    """Claude Code keeps a folder's sessions in ~/.claude/projects/<folder, / and . as ->."""
    return os.path.join(PROJECTS, re.sub(r'[/.]', '-', os.path.realpath(folder)))


def jsonl(path):
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        yield json.loads(line)
                    except json.JSONDecodeError:
                        pass
    except OSError:
        return


def ts(s):
    try:
        return datetime.fromisoformat(s.replace('Z', '+00:00'))
    except (AttributeError, ValueError):
        return None


def pct(values, p):
    if not values:
        return None
    v = sorted(values)
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))]


def short(text, n=160):
    text = re.sub(r'\s+', ' ', str(text)).strip()
    return text if len(text) <= n else text[:n] + '…'


def error_key(text):
    """Groups errors that differ only by ids, numbers and quoted values."""
    t = short(text, 120)
    t = re.sub(r'"[^"]*"', '"…"', t)
    t = re.sub(r"'[^']*'", "'…'", t)
    return re.sub(r'\d+', 'N', t)


def read_transcript(path):
    """Tool calls, tool errors with their text, latency per tool, model time, length."""
    first = last = None
    tool_of, started = {}, {}
    calls, errors = Counter(), Counter()
    error_texts = defaultdict(Counter)
    latency = defaultdict(list)
    think = []
    prev_result_at = None
    for e in jsonl(path):
        at = ts(e.get('timestamp'))
        if at:
            first = first or at
            last = at
        msg = e.get('message') or {}
        content = msg.get('content')
        if not isinstance(content, list):
            continue
        if e.get('type') == 'assistant':
            if prev_result_at and at:
                think.append((at - prev_result_at).total_seconds())
                prev_result_at = None
            for c in content:
                if c.get('type') == 'tool_use':
                    tool_of[c.get('id')] = c.get('name', '?')
                    started[c.get('id')] = at
                    calls[c.get('name', '?')] += 1
        elif e.get('type') == 'user':
            for c in content:
                if c.get('type') != 'tool_result':
                    continue
                name = tool_of.get(c.get('tool_use_id'), '?')
                if at and started.get(c.get('tool_use_id')):
                    latency[name].append((at - started[c['tool_use_id']]).total_seconds())
                prev_result_at = at
                if c.get('is_error'):
                    errors[name] += 1
                    body = c.get('content')
                    if isinstance(body, list):
                        body = ' '.join(x.get('text', '') for x in body if isinstance(x, dict))
                    error_texts[name][error_key(body)] += 1
    return {
        'first': first,
        'seconds': (last - first).total_seconds() if first and last else 0,
        'calls': calls,
        'errors': errors,
        'error_texts': error_texts,
        'latency': latency,
        'think': think,
    }


# When Deck started logging a resumed run's own cost (local time, as the
# ledger's at).
CUMULATIVE_UNTIL = '2026-11-23T10:23:31'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--days', type=int, default=7)
    ap.add_argument('--deck')
    ap.add_argument('--no-save', action='store_true')
    a = ap.parse_args()

    deck = deck_home(a.deck)
    now = datetime.now(timezone.utc)
    since = now - timedelta(days=a.days)
    runs_dir = os.path.join(deck, 'cache', 'runs')

    # The ledger. Before CUMULATIVE_UNTIL, a resumed run's costUsd and
    # apiSeconds held the whole session's (Claude adds them up over --resume):
    # keep only what that run added.
    runs = []
    before = defaultdict(lambda: [0.0, 0])
    every = [r for f in sorted(glob.glob(os.path.join(runs_dir, '*.jsonl'))) if os.path.basename(f) != 'issues.jsonl' for r in jsonl(f)]
    for r in sorted(every, key=lambda r: r.get('at') or ''):
        sid = r.get('sessionId')
        if sid and r.get('resumed') and (r.get('at') or '') < CUMULATIVE_UNTIL:
            prev = before[sid]
            r['costUsd'] = max(0.0, r.get('costUsd', 0) - prev[0])
            r['apiSeconds'] = max(0, r.get('apiSeconds', 0) - prev[1])
        if sid:
            before[sid][0] += r.get('costUsd', 0)
            before[sid][1] += r.get('apiSeconds', 0)
        at = ts(r.get('at'))
        if at and (at if at.tzinfo else at.astimezone()) >= since:
            runs.append(r)

    # The transcripts: every ledger run with a session id, plus the worker
    # folder's sessions the ledger does not know (before it existed).
    seen = set()
    sessions = []
    for r in runs:
        sid = r.get('sessionId')
        if sid and r.get('dir'):
            path = os.path.join(transcript_dir(r['dir']), sid + '.jsonl')
            if os.path.exists(path) and path not in seen:
                seen.add(path)
                sessions.append((r['kind'].split(':')[0], path, r))
    worker = transcript_dir(os.path.join(deck, 'cache', 'worker'))
    for path in glob.glob(os.path.join(worker, '*.jsonl')):
        if path in seen or datetime.fromtimestamp(os.path.getmtime(path), timezone.utc) < since:
            continue
        seen.add(path)
        sessions.append(('worker', path, None))

    by_kind = defaultdict(lambda: {
        'runs': 0, 'outcomes': Counter(), 'seconds': [], 'cost': [], 'turns': [], 'tokens': Counter(),
        'denials': Counter(), 'mcpFailed': Counter(), 'errors': Counter(), 'subjects': Counter(),
    })
    for r in runs:
        k = by_kind[r['kind']]
        k['runs'] += 1
        k['outcomes'][r.get('outcome', '?')] += 1
        k['seconds'].append(r.get('seconds', 0))
        k['cost'].append(r.get('costUsd', 0))
        if r.get('turns'):
            k['turns'].append(r['turns'])
        k['tokens'].update(r.get('tokens') or {})
        k['denials'].update(r.get('denials') or [])
        k['mcpFailed'].update(r.get('mcpFailed') or [])
        if r.get('error'):
            k['errors'][error_key(r['error'])] += 1
        if r.get('subject'):
            k['subjects'][r['subject']] += 1

    tx = defaultdict(lambda: {
        'sessions': 0, 'seconds': [], 'calls': Counter(), 'errors': Counter(), 'error_texts': defaultdict(Counter),
        'latency': defaultdict(list), 'think': [], 'with_errors': 0,
    })
    worst = []
    for kind, path, r in sessions:
        t = read_transcript(path)
        k = tx[kind]
        k['sessions'] += 1
        k['seconds'].append(t['seconds'])
        k['calls'].update(t['calls'])
        k['errors'].update(t['errors'])
        for name, texts in t['error_texts'].items():
            k['error_texts'][name].update(texts)
        for name, v in t['latency'].items():
            k['latency'][name].extend(v)
        k['think'].extend(t['think'])
        if t['errors']:
            k['with_errors'] += 1
        worst.append({
            'kind': kind,
            'transcript': path,
            'log': os.path.join(runs_dir, 'logs', r['id'] + '.log') if r else None,
            'outcome': r.get('outcome') if r else None,
            'error': r.get('error') if r else None,
            'seconds': round(t['seconds']),
            'costUsd': r.get('costUsd') if r else None,
            'toolErrors': sum(t['errors'].values()),
            'calls': sum(t['calls'].values()),
        })

    issues = [i for i in jsonl(os.path.join(runs_dir, 'issues.jsonl')) if (ts(i.get('at')) or now).astimezone(timezone.utc) >= since]

    def stats(values):
        values = [v for v in values if v is not None]
        return {'n': len(values), 'p50': pct(values, .5), 'p90': pct(values, .9), 'max': max(values) if values else None}

    out = {
        'deck': deck,
        'from': since.date().isoformat(),
        'to': now.date().isoformat(),
        'ledger': {
            kind: {
                'runs': k['runs'],
                'outcomes': dict(k['outcomes']),
                'seconds': stats(k['seconds']),
                'costUsd': {'total': round(sum(k['cost']), 4), 'p50': pct(k['cost'], .5)},
                'turns': stats(k['turns']),
                'tokens': dict(k['tokens']),
                'denials': k['denials'].most_common(10),
                'mcpFailed': k['mcpFailed'].most_common(5),
                'errors': k['errors'].most_common(10),
                'topSubjects': k['subjects'].most_common(5),
            }
            for kind, k in sorted(by_kind.items())
        },
        'transcripts': {
            kind: {
                'sessions': k['sessions'],
                'withToolErrors': k['with_errors'],
                'seconds': stats(k['seconds']),
                'calls': k['calls'].most_common(15),
                'toolErrors': k['errors'].most_common(10),
                'errorTexts': {name: texts.most_common(5) for name, texts in k['error_texts'].items()},
                'toolLatencySeconds': {
                    name: {'p50': round(pct(v, .5), 1), 'p90': round(pct(v, .9), 1), 'n': len(v)}
                    for name, v in sorted(k['latency'].items(), key=lambda x: -sum(x[1]))[:10]
                },
                'modelSecondsBetweenTools': stats([round(x, 1) for x in k['think']]),
            }
            for kind, k in sorted(tx.items())
        },
        'issues': {
            'count': len(issues),
            'byKind': Counter(i.get('kind') for i in issues).most_common(),
            'items': [
                {key: i.get(key) for key in ('at', 'kind', 'what', 'detail', 'tool', 'run', 'project', 'review', 'ledger') if i.get(key)}
                for i in issues[-40:]
            ],
        },
        'toRead': {
            'failed': [w for w in worst if w['outcome'] not in (None, 'ok')][:8],
            'mostToolErrors': sorted(worst, key=lambda w: -w['toolErrors'])[:5],
            'slowest': sorted(worst, key=lambda w: -w['seconds'])[:5],
        },
    }

    insights = os.path.join(deck, 'cache', 'insights')
    previous = sorted(glob.glob(os.path.join(insights, '*.json')))
    previous = [p for p in previous if os.path.basename(p) != now.date().isoformat() + '.json']
    if previous:
        prev = json.load(open(previous[-1]))
        out['previous'] = {
            'file': previous[-1],
            'ledger': {k: {'runs': v['runs'], 'outcomes': v['outcomes'], 'seconds': v['seconds'], 'costUsd': v['costUsd']} for k, v in prev.get('ledger', {}).items()},
            'transcripts': {k: {'sessions': v['sessions'], 'withToolErrors': v['withToolErrors']} for k, v in prev.get('transcripts', {}).items()},
            'issues': prev.get('issues', {}).get('count'),
        }
    if not a.no_save:
        os.makedirs(insights, exist_ok=True)
        with open(os.path.join(insights, now.date().isoformat() + '.json'), 'w') as f:
            json.dump({k: v for k, v in out.items() if k != 'previous'}, f, indent=1, default=str)
    json.dump(out, sys.stdout, indent=1, default=str)
    print()


if __name__ == '__main__':
    main()
