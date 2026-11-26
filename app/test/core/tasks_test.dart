import 'package:deck/claude/tasks.dart';
import 'package:deck/core/models/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 11, 3);
  const projects = [
    ProjectConfig(id: 'vpn', name: 'Acme VPN', aliases: ['com.acme.vpn', 'AVPN']),
    ProjectConfig(id: 'web', name: 'Website'),
  ];

  for (final provider in ['slack', 'mail']) {
    test('$provider asks Claude to tag each record with a project', () {
      final t = taskFor(provider, const ProviderConfig(), null, now, projects: projects)!.task;
      expect(t.input['projects'], [
        {
          'id': 'vpn',
          'name': 'Acme VPN',
          'aliases': ['com.acme.vpn', 'AVPN'],
        },
        {'id': 'web', 'name': 'Website'},
      ]);
      expect(t.instructions, contains('project (the id of the entry in input.projects'));
    });

    test('$provider without projects says nothing about them', () {
      final t = taskFor(provider, const ProviderConfig(), null, now)!.task;
      expect(t.input.containsKey('projects'), isFalse);
      expect(t.instructions, isNot(contains('input.projects')));
    });
  }

  test('slack searches project channels for team asks, and Jira for an existing ticket', () {
    const ps = [
      ProjectConfig(id: 'vpn', name: 'VPN', board: 'jira:OM', channels: ['#vpn-apps', 'abp-vpn']),
      ProjectConfig(id: 'ios', name: 'iOS', channels: ['#vpn-apps']),
    ];
    final s = taskFor('slack', const ProviderConfig(), null, now, projects: ps, cards: const [(key: 'jira:OM-7', ref: 'OM-7', title: 'Purchase fails')]);
    final t = s!.task;
    expect(t.input['queries'], ['to:me after:2026-10-30', 'in:#vpn-apps after:2026-10-30', 'in:#abp-vpn after:2026-10-30']);
    // Mentions: the user's id as keyword, since Slack ignores a mention in filters.
    expect(t.input['mentions'], 'after:2026-10-30');
    expect(t.instructions, contains('keywords ["<@ID>"]'));
    expect(t.input['cards'], [
      {'ref': 'OM-7', 'title': 'Purchase fails'},
    ]);
    expect((t.input['projects']! as List).first, containsPair('board', 'jira:OM'));
    expect(t.instructions, contains('team (true'));
    expect(t.instructions, contains('searchJiraIssuesUsingJql'));
    expect(s.tools, contains('mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql'));
    // No channels: only asks aimed at you, no Jira search.
    final plain = taskFor('slack', const ProviderConfig(), null, now)!;
    expect(plain.task.instructions, isNot(contains('team (true')));
    expect(plain.tools, hasLength(2));
  });

  test('Jira tools follow the connector option, in the Jira, Slack and ticket tasks', () {
    const c = 'claude_ai_Atlassian_v2';
    final jira = taskFor('jira', const ProviderConfig(options: {'connector': c}), null, now)!;
    expect(jira.tools, contains('mcp__claude_ai_Atlassian_v2__searchJiraIssuesUsingJql'));
    expect(jira.tools.where((t) => t.startsWith('mcp__claude_ai_Atlassian__')), isEmpty);
    const ps = [
      ProjectConfig(id: 'vpn', name: 'VPN', board: 'jira:OM', channels: ['#vpn-apps']),
    ];
    expect(
      taskFor('slack', const ProviderConfig(), null, now, projects: ps, atlassian: c)!.tools,
      contains('mcp__claude_ai_Atlassian_v2__searchJiraIssuesUsingJql'),
    );
    expect(ticketTask('OM', 'T', 'B', now, atlassian: c).tools, contains('mcp__claude_ai_Atlassian_v2__createJiraIssue'));
    // The prompts name the allowed server, so ToolSearch does not load the default one's tools.
    final slack = taskFor('slack', const ProviderConfig(), null, now, projects: ps, atlassian: c)!.task;
    for (final t in [jira.task, slack, ticketTask('OM', 'T', 'B', now, atlassian: c).task]) {
      expect(t.instructions, contains('start with mcp__claude_ai_Atlassian_v2__ '));
    }
  });

  test('the connector option takes a pasted tool prefix, and blank is the default', () {
    expect(atlassianTool('getJiraIssue', ' mcp__claude_ai_Atlassian_v2__ '), 'mcp__claude_ai_Atlassian_v2__getJiraIssue');
    expect(atlassianTool('getJiraIssue', 'claude_ai_Atlassian_v2'), 'mcp__claude_ai_Atlassian_v2__getJiraIssue');
    expect(atlassianTool('getJiraIssue', '  '), 'mcp__claude_ai_Atlassian__getJiraIssue');
    expect(atlassianTool('getJiraIssue'), 'mcp__claude_ai_Atlassian__getJiraIssue');
    // A comma would add tools to --allowedTools: such a name is not used.
    expect(atlassianTool('getJiraIssue', 'x,Bash'), 'mcp__claude_ai_Atlassian__getJiraIssue');
  });

  test('slack with a workspace leaves url to Deck, which builds it from the id', () {
    final t = taskFor('slack', const ProviderConfig(options: {'workspace': 'https://acme.slack.com/'}), null, now)!.task;
    expect(t.input['workspace'], 'acme');
    expect(t.instructions, isNot(contains('url (')));
    final r = withSlackUrls([
      {'id': 'D1/1795178168.800749', 'title': 'Hi'},
      {'id': 'C1/1.2', 'url': 'https://kept'},
    ], t.input);
    expect(r.first['url'], 'https://acme.slack.com/archives/D1/p1795178168800749');
    expect(r.last['url'], 'https://kept');
    expect(taskFor('slack', const ProviderConfig(), null, now)!.task.instructions, contains('url (the permalink'));
  });

  test('jira and github keep to the projects set up in Deck when asked', () {
    const ps = [ProjectConfig(id: 'vpn', name: 'VPN', repo: 'github:acme/vpn', board: 'jira:AVPN'), ProjectConfig(id: 'web', name: 'Web', board: 'jira:WEB')];
    const on = ProviderConfig(projectsOnly: true);
    final jira = taskFor('jira', on, null, now, projects: ps)!.task.input;
    expect(jira['jql'], 'project in ("AVPN", "WEB") AND assignee = currentUser() AND statusCategory != Done AND updated >= -180d');
    expect(jira['escalations'], startsWith('project in ("AVPN", "WEB") AND '));
    expect(taskFor('jira', const ProviderConfig(), null, now, projects: ps)!.task.input['jql'], startsWith('assignee = currentUser()'));
    final gh = taskFor('github', on, null, now, projects: ps)!.task;
    expect(gh.input['repos'], ['acme/vpn']);
    expect(gh.instructions, contains('only in the repositories listed in input.repos'));
    expect(taskFor('github', const ProviderConfig(), null, now, projects: ps)!.task.input.containsKey('repos'), isFalse);
  });

  group('mail search', () {
    final at9 = DateTime(2026, 11, 3, 9);
    List<Object?> days(DateTime? since) => taskFor('mail', const ProviderConfig(), since, at9)!.task.input['days'] as List? ?? const [];

    test('the first fetch takes the newest 50 threads', () {
      final t = taskFor('mail', const ProviderConfig(), null, at9)!.task;
      expect(t.input['query'], 'in:inbox');
      expect(t.input.containsKey('days'), isFalse);
    });

    test('searches day by day from the day before the last check, oldest first', () {
      expect(days(DateTime(2026, 11, 3, 8)), [
        {'day': '2026-11-02', 'query': 'in:inbox after:2026/11/02 before:2026/11/03'},
        {'day': '2026-11-03', 'query': 'in:inbox after:2026/11/03 before:2026/11/04'},
      ]);
      expect([for (final d in days(DateTime(2026, 10, 31, 18))) (d! as Map)['day']], ['2026-10-30', '2026-10-31', '2026-11-01', '2026-11-02', '2026-11-03']);
    });

    test('gives a run at most a week of days, the next run goes on', () {
      expect(
        [for (final d in days(DateTime(2026, 10, 1))) (d! as Map)['day']],
        ['2026-09-30', '2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04', '2026-10-05', '2026-10-06'],
      );
    });

    group('progress', () {
      final since = DateTime(2026, 10, 31, 18);
      final input = taskFor('mail', const ProviderConfig(), since, at9)!.task.input;
      Map<String, Object?> search(String day, int threads, [String? part]) => {'day': day, 'part': ?part, 'threads': threads};

      test('every day searched: checked up to now', () {
        final days = ['2026-10-30', '2026-10-31', '2026-11-01', '2026-11-02', '2026-11-03'];
        final p = mailProgress(input, [for (final d in days) search(d, 3)], since, at9);
        expect(p.at, at9);
        expect(p.cut, isEmpty);
      });

      test('a run that stopped early is checked up to the first day it did not search', () {
        final p = mailProgress(input, [search('2026-10-30', 1), search('2026-10-31', 4), search('2026-11-01', 40)], since, at9);
        expect(p.at, DateTime(2026, 11, 2));
      });

      test('never goes back before the last check', () {
        expect(mailProgress(input, [search('2026-10-30', 1)], since, at9).at, since);
      });

      test('names the searches Gmail cut off at 50, not a day split in parts that each fit', () {
        final p = mailProgress(
          input,
          [
            search('2026-10-30', 50),
            search('2026-10-31', 50),
            search('2026-10-31', 20, 'Primary'),
            search('2026-10-31', 50, 'Updates'),
            search('2026-11-01', 50),
            search('2026-11-01', 12, 'Primary'),
          ],
          since,
          at9,
        );
        expect(p.cut, ['2026-10-30', '2026-10-31 (Updates)']);
      });
    });
  });

  group('inbox listing', () {
    final now = DateTime(2026, 11, 3, 9);

    test('searches the inbox ten senders at a time, nothing without a sender', () {
      expect(inboxTask(const [], now), isNull);
      final senders = [for (var i = 0; i < 12; i++) 's$i@acme.com'];
      final searches = inboxTask([...senders, 's0@acme.com'], now)!.task.input['searches']! as List;
      expect(searches, hasLength(2));
      expect((searches.last as Map)['query'], 'in:inbox {from:s8@acme.com from:s9@acme.com}');
    });

    test('a search cut off at 50 threads closes nothing for its senders', () {
      final input = inboxTask(['a@acme.com', 'b@acme.com'], now)!.task.input;
      final query = ((input['searches']! as List).single as Map)['query'];
      expect(
        inboxBySender(input, [
          {
            'query': query,
            'ids': ['t1'],
          },
        ]),
        {
          'a@acme.com': {'t1'},
          'b@acme.com': {'t1'},
        },
      );
      expect(
        inboxBySender(input, [
          {
            'query': query,
            'ids': [for (var i = 0; i < 50; i++) 't$i'],
          },
        ]),
        isEmpty,
      );
    });
  });

  group('recordProblems', () {
    const good = {'id': 'a1', 'url': 'https://x', 'at': '2026-10-30T18:29:26Z', 'title': 'Workload review'};

    test('accepts complete mail records', () {
      expect(recordProblems('mail', [good]), isNull);
    });

    test('refuses mail records without at or url, naming them', () {
      final p = recordProblems('mail', [
        good,
        {'id': 'b2', 'title': 'Workload review', 'kind': 'fyi'},
      ]);
      expect(p, contains('1 of 2 records'));
      expect(p, contains('record 1 (id b2): no url, at'));
    });

    test('names the missing end of a calendar event', () {
      final p = recordProblems('calendar', [
        {'id': 'e1', 'title': 'Guild', 'start': '2026-11-23T14:00:00+01:00'},
      ]);
      expect(p, contains('record 0 (id e1): no end'));
    });

    test('a mail run given days must list the searches it ran, apart from the threads', () {
      final input = taskFor('mail', const ProviderConfig(), DateTime(2026, 11, 3, 8), DateTime(2026, 11, 3, 9))!.task.input;
      expect(recordProblems('mail', [good], input), contains('one record per search you ran'));
      expect(
        recordProblems('mail', [
          good,
          {'day': '2026-11-03', 'threads': 1},
        ], input),
        isNull,
      );
    });

    test('does not check notes or archive runs', () {
      expect(recordProblems('notes', [{}]), isNull);
      expect(recordProblems(archiveProvider, [{}]), isNull);
    });
  });
}
