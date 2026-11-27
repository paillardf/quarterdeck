// The providers Deck knows, and what each one can do.
import 'models/config.dart';

class ProviderInfo {
  const ProviderInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.access,
    this.cli,
    this.options = const {},
    this.scoped = false,
  });

  final String id;
  final String name;
  final String description;

  /// Access modes this provider supports, best first.
  final List<Access> access;

  /// The command line tool behind [Access.cli].
  final String? cli;

  /// Option key → label, shown in Settings.
  final Map<String, String> options;

  /// Can keep to the projects set up in Deck ([ProviderConfig.projectsOnly]).
  final bool scoped;
}

const providerCatalog = <ProviderInfo>[
  ProviderInfo(
    id: 'gitlab',
    name: 'GitLab',
    description: 'Merge requests you wrote, are assigned to, or review.',
    access: [Access.cli, Access.claude],
    cli: 'glab',
    scoped: true,
  ),
  ProviderInfo(
    id: 'github',
    name: 'GitHub',
    description: 'Pull requests you wrote, are assigned to, or review.',
    access: [Access.cli, Access.claude],
    cli: 'gh',
    scoped: true,
  ),
  ProviderInfo(
    id: 'jira',
    name: 'Jira',
    description: 'Open issues assigned to you.',
    access: [Access.claude],
    options: {'escalationType': 'Escalation issue type', 'site': 'Site', 'connector': 'Atlassian connector, as /mcp shows it (default claude.ai Atlassian)'},
    scoped: true,
  ),
  ProviderInfo(
    id: 'slack',
    name: 'Slack',
    description: 'DMs and mentions that ask something of you. Claude judges each one.',
    access: [Access.claude],
    options: {
      'queries': 'Extra search filters, like in:#channel (comma separated; DMs and mentions are already searched)',
      'workspace': 'Workspace, as in <workspace>.slack.com (for message links)',
    },
  ),
  ProviderInfo(
    id: 'calendar',
    name: 'Calendar',
    description: 'Your meetings of the next 24 hours, with a join button. Meetings you accepted ring before they start.',
    access: [Access.claude],
    options: {'alarmMinutes': 'Alarm, minutes before the start (default 2)'},
  ),
  ProviderInfo(
    id: 'mail',
    name: 'Mail',
    description: 'Your inbox, sorted by Claude: asks, FYI, noise (one card per sender, with a Gmail filter button) and phishing.',
    access: [Access.claude],
    options: {
      'query': 'Search query (default in:inbox)',
      'notesName': 'Your name in Gemini meeting notes, e.g. Ann Lee (empty: off). Next steps for you become todos.',
    },
  ),
];

ProviderInfo providerInfo(String id) => providerCatalog.firstWhere((p) => p.id == id);
