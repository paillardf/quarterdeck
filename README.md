# Quarterdeck

A desktop board of everything on your plate: merge requests, reviews, tickets,
Slack and mail asks, meetings and todos, ranked by what needs you. One click
starts the work: a Claude Code session, a worktree, your IDE, or a code review.

macOS is the daily driver. Linux and Windows build but are **experimental**:
they have not been used day to day.

![The board: what to do next, what is in progress, what waits on others](docs/screenshots/board.png)

> [!WARNING]
> **Quarterdeck was written mostly by AI ("vibe coded") for one person's
> workflow.** It is shared as is, with no warranty (see [LICENSE](LICENSE)).
> Use it at your own risk.
>
> **It runs Claude in the background, with your login and your money.** Once
> providers are on, Quarterdeck starts `claude -p` sessions by itself that read
> your Slack, mail, Jira and calendar, can act on your machine, and cost tokens.
> Messages from other people end up in prompts, so prompt injection is a real
> risk. A local MCP server on port 4777 has no authentication.
>
> Turn off any provider in Settings, and set the daily budget (Settings › Claude)
> before you start.

## Install

**macOS and Linux**

```
curl -fsSL https://raw.githubusercontent.com/paillardf/quarterdeck/main/install.sh | sh
```

**Windows** (PowerShell)

```
irm https://raw.githubusercontent.com/paillardf/quarterdeck/main/install.ps1 | iex
```

The script installs the latest release (macOS: `/Applications`, Linux:
`~/.local/share/quarterdeck` with a `quarterdeck` command and an app menu entry,
Windows: `%LOCALAPPDATA%\Quarterdeck` with a Start menu shortcut). It then
checks what Quarterdeck uses and offers to fix what is missing: Claude Code,
the `deck` MCP server for your own Claude sessions, `gh` and `glab` and their
logins. Quarterdeck then tells you when a new release is out and updates
itself in one click (Settings › General › Updates); running the script again
also updates. Read it first if you like:
[install.sh](install.sh), [install.ps1](install.ps1).

The macOS build is signed with a Developer ID and notarized by Apple. The
Windows build is not signed yet: SmartScreen may warn about an unknown
publisher (More info › Run anyway).

<details>
<summary>Manual install</summary>

Download the latest build from
[Releases](https://github.com/paillardf/quarterdeck/releases):

- **macOS:** open `Quarterdeck-macos.dmg` and drag Quarterdeck to Applications.
- **Linux:** unpack `Quarterdeck-linux-x64.tar.gz` and run `./deck` (needs
  GTK 3 and libnotify).
- **Windows:** unzip `Quarterdeck-windows-x64.zip` and run `deck.exe`.

</details>

**Uninstall:** delete the app (`/Applications/Quarterdeck.app`,
`~/.local/share/quarterdeck` plus `~/.local/bin/quarterdeck` and
`~/.local/share/applications/quarterdeck.desktop`, or
`%LOCALAPPDATA%\Quarterdeck`), then `claude mcp remove deck`. Your data stays
in `~/.deck`.

## What you need

| Need | For |
|---|---|
| [Claude Code](https://claude.com/claude-code), logged in (`claude`) | Background runs and every Claude button |
| `glab` logged in | GitLab merge requests, reviews and issues (no tokens spent) |
| `gh` logged in | GitHub pull requests, reviews and issues (no tokens spent) |
| claude.ai connectors: **Slack**, **Gmail**, **Google Calendar**, **Atlassian** | The Slack, Mail, Calendar and Jira providers |
| An IDE command on your PATH (`code`, `cursor`, `idea`...) | Open in IDE |

You only need what your providers use. The connector providers expect the
claude.ai connectors by their default names (`claude_ai_Slack`,
`claude_ai_Gmail`, `claude_ai_Google_Calendar`, `claude_ai_Atlassian`): a Slack
MCP server you configured yourself under another name is not picked up. For an
Atlassian connector under another name, set its name in the Jira provider's
options; Slack's Jira search, Make ticket and review sessions use it too.
Mail is Gmail only (meeting notes come from Gemini notes mail).

## Set up

1. Open Settings › Providers and turn on the ones you use.
2. Settings › Projects: add your project folders. Quarterdeck reads each one
   once with Claude for its product name, icon and ticket prefix.
3. Settings › Claude: models, refresh interval and the daily budget.

Data lives in `~/.deck` (change it in Settings › General): `deck.json`,
`state/` (your triage, todos and activity, kept in a local git repo) and
`cache/` (safe to delete).

Any Claude Code session can add todos to the board through the MCP server.
The install script registers it; by hand:

```
claude mcp add --scope user --transport http deck http://127.0.0.1:4777/mcp
```

## Features

All screenshots use made up data.

### The board

- **Flow** (home): Next, Doing, Waiting, Done today. Next is one list ranked
  across all sources.
  Doing holds what you started or where Claude waits for you, 3 at most.
- **Focus**: one large Now card, a small Doing row, then the queue. For when
  you do not want to choose.
- **By Type**: Replies, Reviews, My MRs and Tasks, for triage.
- Every card says what it is, where it came from and the next step, with the
  buttons for it: Start Review, Address Feedback, Claude, Open in IDE, Draft
  Reply, Make Ticket...
- Triage: pin, mark urgent, snooze, add a note, done. Drag a card to another
  column to move it.
- Linked cards: a Slack ask, the Jira ticket it is about and the MR that fixes
  it show each other as chips. Drag one card onto another to link them.
- One filter field for project, type, provider and title search.
- Today's meetings sit in one line above the board, with Join and an alarm
  that rings before they start.

![By Type: replies, reviews, your merge requests and tasks](docs/screenshots/by_type.png)

### Sources

| Source | How it is read | Cost |
|---|---|---|
| GitLab, GitHub | `glab` / `gh` with your login: your MRs, reviews, issues, pipelines | No tokens |
| Jira, Slack, Mail, Calendar | A background Haiku session through your claude.ai connectors, which judges whether a message is an ask for you | About $0.01 a run, capped by your daily budget |

- Mail: low value mail (noise, FYI, phishing) folds into one Quick sweep card.
  Archive in one click, or turn a noisy sender into a Gmail filter.
- Each Slack or mail ask is tagged with its project, from the project names
  and other names Quarterdeck knows.

### Code review

Review merge requests and pull requests inside Quarterdeck. Claude prepares
the review: it cuts the change into chapters, checks it against the ticket,
hides the noise (lockfiles, moved files, renames) and drafts comments.

- Each thread is a talk with Claude (never posted) and one answer. Accept or
  reject each answer; only accepted ones go out when you publish.
- Ask Claude about any line, or ask it to fix accepted threads. Fixes are
  commits on the review's branch, in a worktree; your own checkout never moves
  and Quarterdeck never force-pushes.
- Publish shows what goes out and what is skipped before anything is posted.

![A merge request review with Claude's draft threads](docs/screenshots/review.png)

### Projects

Add a project folder and Claude reads it once for its product name, icon,
platforms, Jira key and Slack channels.

- **Overview**: what changed on the project by day (from Slack, mail and
  merged MRs), the documents shared about it, and facts (release, decisions,
  people, open questions) kept current by Claude. Edit any line.
- **Map**: each feature of the project drawn as classes, a step by step flow
  and a state machine, all clickable. Claude writes the map; it stays in
  `.skim/map/` in the repo.
- **Talk about a project**: a Claude session in the project folder with the
  project's overview, map and MRs as tools.
- **New Task**: a branch name, a worktree from the default branch, and Claude
  started in it. No ticket needed.

![Project overview: what changed, documents, facts](docs/screenshots/project_overview.png)

![A feature drawn as classes and a flow](docs/screenshots/project_feature.png)

### Activity

A log of what you did, from evidence, not a journal: cards done, MRs merged,
approvals given, meetings attended, Claude Code sessions (read from their
transcripts). Day, week, month and year views, and a review or standup written
by Claude from the log in one click.

![Activity for a week with its review](docs/screenshots/activity.png)

### Claude sessions and notifications

- A terminal panel at the bottom runs the Claude sessions you start. Each tab
  shows whether Claude is working, waits for you or is done, and tabs come back
  after a restart.
- When a background session asks for a tool, the ask floats over every screen:
  Allow, Deny, or Always Allow with a rule you edit. Toasts tell you when a
  review is ready, a map is done or a run failed.
- Any Claude Code session can add todos and log activity through the MCP
  server (see Set up).

![A tool ask and a toast over the board](docs/screenshots/notices.png)

## Build from source

Needs Flutter (stable, see `.github/workflows/release.yml` for the version).

```
cd app
flutter run -d macos     # or linux, windows
```

[`app/README.md`](app/README.md) has the code layout and test commands.
[`DESIGN.md`](DESIGN.md) explains the decisions, [`BACKLOG.md`](BACKLOG.md)
lists what is not done yet.

## License

MIT, see [LICENSE](LICENSE).
