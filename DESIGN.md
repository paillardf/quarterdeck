# Deck: design

One desktop board for everything on your plate: merge requests, reviews,
tickets, Slack and mail asks, todos. It ranks what to do next and starts the
work (Claude session, worktree, IDE, review) in one click.

Status: Flutter app working on macOS with live data, 2026-10-15. Code in `app/`.
A Node prototype came first; it is gone.

## Goals

- Open Deck and see, without asking anyone: what needs me, what waits on
  others, what I decided to snooze.
- The less work the AI does, the better: rules and direct calls first, Claude
  only for what needs a connector or judgement.
- One click starts the work in the right folder.
- Shareable with colleagues: every provider, project and action is set in the
  Settings window. Nothing hard coded (no company paths, no note app).

## Non goals

- Not a journal, not a replacement for GitLab, Jira or Slack UIs (cards link out).
  Exception: code review, see "Code review in Deck".
  Deck keeps a raw activity log (one line per event, see below); writing
  standups or reviews from it is Claude's job, through `deck_activity`.
- No team view. One person, one Deck.

## Architecture

```
 Deck.app (Flutter: macOS, Linux, Windows)
   ├─ board + Settings window (Riverpod state)
   ├─ direct sources ── glab / gh CLI ──► GitLab, GitHub   0 tokens
   ├─ background worker ── claude -p --model haiku ──► claude.ai connectors (Jira, Slack, Mail)
   │        the app writes each task (queries, record shape); Claude executes and judges
   ├─ Deck MCP server  http://127.0.0.1:4777/mcp
   │        deck_tasks / deck_submit (worker), deck_add_todo, deck_log_activity,
   │        deck_activity, deck_report_issue (any session), deck_permission,
   │        map tools (get_map, set_map_feature, ...) per project
   ├─ map session ── claude -p --model <code model> in the project folder ──► .skim/map/
   └─ launcher: Terminal + claude (prompt file), IDE, /skim-code review
 Deck folder (~/.deck by default): deck.json, state/ (git backed up, activity/ log), cache/ (disposable)
```

Card flow: a source gives records → a classifier (pure Dart rules ported from
the Work Queue artifact) turns each into a card with a bucket (needs you,
waiting, nothing to do) and a one line "next" → your triage (pin, urgent,
boost, snooze, note, done) ranks and hides → project chips filter.

## Decisions and why

**App first, not "a Claude command that starts a website".** The first version
was a Claude Code plugin: `/deck` started a local web page and the session fed
it. The user disliked the unknown lifecycle (page dies with the session). Now
the app owns its lifecycle and starts Claude in the background. Tradeoff: a
desktop app to build and sign instead of a plugin install.

**Deck calls command line tools itself.** When the session read GitLab results
through the claude.ai connector, one refresh cost about 150k tokens (every
result repeats the full MR). The old Work Queue artifact never paid this
because page code, not a model, read the results. Deck runs `glab api` (and
`gh` for GitHub) with the user's own login: 0 tokens, about 5 s, about
2 s when no MR changed. It first spawned the user's local GitLab MCP server
instead; dropped (2026-10-15) because Deck only worked with one server
(`@zereight/mcp-gitlab`, tool names hard coded) while Settings offered any
server, and a CLI is one fixed tool with a known login. Tradeoff: slower than
the MCP server (one process per call), and glab or gh must be installed and
logged in. A provider is fetched either by a CLI or by the Claude session. A separate
Claude step that judges CLI output (asks in messages) gets added only when a
provider fetched by a CLI needs judgement; none does yet.

**Background Claude only for connector sources and judgement.** Slack and mail
need a model to decide "is this an ask for me, is it done, what is needed".
The app writes exact tasks so Claude never plans. Measured: about $0.014 and
35 s per Haiku run. Verdicts are stored with the card.

**Dart/Flutter, not TypeScript.** TS was the first pick (official MCP SDK,
same stack as skim-review, plugin shipping). It stopped fitting once the app
became the starting point: Flutter gives a native desktop app, the user's daily
language, and `dart_mcp` proved enough in the spike. Tradeoff: we wrote an HTTP
transport for `dart_mcp` (about 100 lines), and sharing needs a signed app.

**Open source on GitHub Releases, no stores (2026-11-20).** Deck is shared as
an open source app, built by GitHub Actions on a tag and downloaded from
GitHub Releases, for macOS, Linux and Windows. GitHub over GitLab: free hosted
macOS runners for public repos (GitLab needs a paid tier or a self-hosted
runner), files attach straight to a release, and a Homebrew tap on GitHub needs
no extra URL. Updates start as a card that reads the latest release from the
public API, on every platform; Sparkle waits for a Developer ID. Tradeoff:
unsigned builds show Gatekeeper and SmartScreen warnings until then.

**Riverpod 3.** Most state lives outside widgets (MCP server, background runs,
fetchers, timers). Riverpod works without a BuildContext and in tests.
`provider` needs a
BuildContext. BLoC also works outside the tree but costs an event/state class
per small async flow. Tradeoff: codegen (`build_runner`).

**Activity log from evidence, not a journal.** One JSON line per event in
`state/activity/YYYY-MM.jsonl`: cards done (by you, or by Deck with the
reason), todos added, your MRs merged, approvals you gave, meetings attended,
Claude Code sessions, and lines any session adds with `deck_log_activity`.
Sessions come from the transcripts Claude Code already writes
(`~/.claude/projects`, or `$CLAUDE_CONFIG_DIR/projects` when your shell sets it, with an AI title), not from a hook: 0 tokens, nothing to
install, and sessions run while Deck is closed are still found. Tradeoff: a
session is logged once it has been idle 30 minutes, and approvals are only seen
while Deck runs. The Activity view shows the log; its standup or review is one
`claude -p` call with no tools and no MCP servers (`--tools ""
--strict-mcp-config`), the log in the prompt: titles come from Slack and mail,
so the model that reads them gets nothing to act with.

**Run ledger for every Claude session Deck starts.** Background runs failed
out of sight: the result lived in memory, stderr was cut to one line, one shot
calls kept no transcript. Now `runSession` and `askClaude` (the only two doors
to `claude`) append one line per run to `cache/runs/YYYY-MM.jsonl`: kind,
subject, model, outcome (ok, failed, timeout, stopped, noClaude), time, cost,
tokens, turns, tool calls and tool errors per tool, refused tools, MCP servers
that did not connect, the end of stderr. The raw stream (JSON lines plus
stderr) goes to `cache/runs/logs/<id>.log`, kept 30 days. Every session is
also told to call `deck_report_issue` (always allowed) once per problem Deck
itself causes: a failing tool, instructions it had to guess at, a missing
tool, bad input. Issues go to `cache/runs/issues.jsonl` with the run, project,
review and ledger id from the session's MCP URL (`runSession` adds
`ledger=<id>`), and ring the bell. All of it is read by the
`deck-insights` skill to find what fails, what is slow and what costs. In the
cache, not state: it is diagnostics, not your decisions, and losing it loses
only history. Off by default (Settings › Claude › Keep a run log,
`collectRuns`): it is for whoever works on Deck, it writes your messages'
text into the raw logs, and the report note costs every session tokens. Off,
nothing is written and sessions get neither the note nor the tool.

**Gmail filters do the deterministic mail sorting, not Claude.** The
`email-triage` skill classified every mail against a rules file on each run:
a model doing a filter's job, every day. Now Haiku only judges new mail, and a
noise sender becomes a Gmail filter in one click, so that mail never reaches
the inbox or the model again. No connector can create filters, so the button
opens Gmail's filter form with From filled and you confirm there. Tradeoff:
one extra click in Gmail, and a filter only matches sender (subject rules are
made by hand). Archiving runs as its own Claude session whose only tool is
`unlabel_thread` and whose input is ids from Deck: it reads no mail text, so a
mail cannot steer it.

**Gmail is read day by day (2026-11-25).** The Gmail connector returns at
most 50 threads per search and no next page, and `after:`/`before:` take
dates, not times. So the first fetch takes the newest 50, and later ones
search each day from the day before the last check, oldest first. A run stops
between days after about 60 threads (the 5 minute timeout loses a whole run)
and saves the check time at the first day it did not search, so the next run
goes on and no day is dropped. A day that hits 50 is searched again per Gmail
tab plus the mail in none; a piece that still hits 50 is named in the source
status. The inbox listing that closes archived FYI and noise cards searches
by the cards' senders, ten per search, ids only; a search that hits 50 closes
nothing for its senders.

**Code review in Deck (2026-10-16).** Skim (a local browser review UI with
its own Node server and MCP) moves into Deck: one app for the board, the
project map and the review, no second server and no browser tab. The core is
ported to Dart rather than run as a Node backend: Deck stays one runtime and
the logic (map, diff, anchors, publish) is small enough to port with its
tests. Deck starts the review and map sessions itself, in the project folder,
with the model set in Settings ("Model for code"); the user talks to them
through threads, not a terminal. Diagrams are drawn natively from the mermaid
subset agents write, so they follow the theme and every box and arrow is
clickable on all three OS. Maps stay in Skim's `.skim/map/` format and the
tools keep Skim's names, so both tools read the same maps. Tradeoff: Deck now
replaces part of the GitLab review UI, against the old "cards link out" non
goal, and two copies of the map code exist until Skim is retired.

**Threads in Deck, decisions of M3 (2026-10-20).**
- Claude answers a thread by resuming the review's last session
  (`claude -p --resume`), started when a thread goes to awaiting Claude. It
  still has the diff it read, so an answer costs a short turn instead of a
  fresh read; the cost is one session id stored per review. Skim kept one
  session alive on `skim wait`; Deck has no terminal to keep, and starts the
  session again when a question comes in while one runs.
- Fix now edits only in a working tree on the review's head: the folder
  that already has the branch checked out, else a worktree under
  `cache/worktrees/<project>/<review>`. The reviewer's own checkout and
  branch never move. Skim's rules stay: never touch a file with uncommitted
  edits, a local commit, never push.
- Findings come from the prepare session (step 4 after the triage), so one
  run does it all; Find issues runs step 4 alone. `/code-review` does not run
  headless, so the review method is written in the prompt.
- Skim's sqlite reviews are not migrated: none was ever published, so
  nothing on a merge request depends on them.
- Publishing shows what goes out, what is skipped and why, and the summary
  before anything is posted. The summary carries no tool name.

**A thread is a talk plus one answer (2026-11-02).** Each thread holds the
talk with Claude (never posted) and one answer, the message the next publish
posts: the opening comment, or the reply on a discussion already there.
Claude writes the answer (its finding is one from the start), the user edits
it in place. Accept and Reject are the user's call on that answer, never a
message to Claude: only an accepted answer is posted, and a new answer from
Claude clears the call so the new text is read before it goes out. Fix and
the one click questions (Example, More context, Possible fix, Shorter) are
messages to Claude. Why: drafts, accept and "use as my reply" mixed the talk with what
goes out, so every Claude message needed its own buttons. States are only
open, dismissed, published, resolved; a thread waiting on Claude is a flag.
Old reviews are converted on load. Tradeoff: the talk on a thread is lost to
the forge on purpose; only the answer goes out.
- One Claude session per review, every run resumes it (prepare, answers,
  Address Feedback, fixes). Runs are serial, which matches one click at a
  time. "Open the session in a terminal" resumes the same session in a Deck
  tab with the review tools; Deck asks it nothing while that tab is open, or
  the two histories would split.
- A fix stores its commit on the thread. Deck reads from git whether it is
  pushed, and Publish skips an answer whose fix is not on the forge yet, so
  "Fixed in abc" never names a commit the reviewer cannot see. Push asks
  first and goes to the merge request's source branch.

**Decide, fix all, publish (2026-11-06).** A thread card reads top to
bottom: what is on the merge request, the answer with Accept and Reject in
its header, then the talk with Claude and the box to write in, last, as in
a chat. Fix left the card: on a branch that is yours (own merge request or
local branch) the thread panel lists the accepted threads with no fix as
"To fix", and one button sends Fix to all of them in one session. Claude
skips the ones that ask for no code change. Why: deciding, fixing and
posting were mixed on each card, and a review of your own branch is about
fixing first. Without a merge request nothing says "post". The thread chat
may change the merge request itself when you ask (title, description, your
comments already posted) through `glab mr update` or a note edit scoped to
that merge request; new comments still go out only with Publish. Tradeoff:
those edits are live at once, with no preview.

**Updates in one click (2026-11-24).** A minute after start and once a day
(Settings > General > Updates can turn it off), Deck reads the latest GitHub
release (`sources/releases.dart`, no token) and compares it with the version
the release workflow built in (`--dart-define=DECK_VERSION`; a local build is
"dev" and never offers one). A newer one floats over every screen with What's
New, Later (until a newer release) and Update. Update runs the same
`install.sh` / `install.ps1` a first install uses, pinned to that version, in
app-only mode (no setup questions), with `QUARTERDECK_PID`: the script
downloads the build, checks it against the release's `SHA256SUMS`, quits Deck
(asked first, killed after 10 s), replaces it and opens the new one. Output
goes to `cache/update.log`; if the script ends while Deck still runs, the
notice says it failed and where to look. Why: one code path for install and
update, on every platform, and the macOS build is notarized so no Gatekeeper
step. Tradeoff: the script comes from `main` at update time, so a broken
script on `main` breaks updates until fixed; Sparkle would be more native on
macOS but needs an appcast and covers one platform.

**Notifications over every screen (2026-11-06).** The ringing meeting and
the tools a background session asks for were banners on the board only, so
on a review or in Settings they waited unseen and asks timed out. They now
float top right over every screen (`NoticeLayer`, in the router shell), with
toasts for sessions that end (review ready, map done, a run failed). A bell
beside the Terminals pill opens the list since Deck started. A permission
ask has Always Allow: you edit the suggested rule (`Bash(rtk git diff:*)`),
it joins Settings > Claude > Allowed tools, which every background session
gets. Every ask is logged in `cache/permission_asks.jsonl`; Settings lists
them and Claude (no tools, the asks as data) suggests rules you add one by
one. Why: rules typed by hand were missing the `rtk` prefix the user's hook
adds, and nothing showed what was asked. Tradeoff: one list for all
sessions, so a rule added for reviews also opens it to the mail run.

**Project info read by Claude (2026-11-03).** Adding a project starts one
Haiku session in its folder (read only tools, no edits) that saves the product
name, a description, other names (app and store names, bundle ids, ticket
prefixes), the app icon, platforms, tech, task board (Jira key from commit
prefixes), Slack channels (channel search only) and IDE through
`set_project_info`. It splits the survey over three helpers that run at the
same time (manifests and icon, git, Slack). Deck sets the repo itself from the
origin remote, and makes the repo the task board when its issues are in use
(one changed in the last 6 months; open ones alone missed a quiet sprint).
Only then does Claude look for a Jira key, and it skips company wide boards:
commit prefixes once picked the company Operations and Maintenance board.
Deck also keeps an IDE only if the command is on PATH. What the run
finds replaces what was set, what it does not find stays; Analyze (Settings,
or the wand on the project page) says so before it runs. Platforms show as a
badge on the logo, not in the name: the name is what messages say, so it
must stay the product name, and Haiku gets the platforms to tell two apps of
one product apart. Why: the folder
name ("vpn-multiplatform") is not what Slack and mail say ("Acme VPN"), so
messages landed in "other". The Slack and mail tasks now get every project's
name and other names and set `project` on each record. The icon is copied to
`state/projects/` (backed up, safe from branch switches) under a new name each
time, so the image cache never shows the old one. Tradeoff: tagging a message
is Haiku's call, not a rule. The icon is PNG, JPEG, WebP or SVG
(`flutter_svg`): drawing SVG in Deck beats asking the session to convert it,
which would need a shell tool and a converter that may not be installed. ICO,
icns and Android vector XML are not read.

**Deleting a review (2026-11-03).** Delete (review page or its MR row)
drops the review file, its fix worktree and the `skim/mr-<iid>` branch Deck
fetched; a review on your own local branch keeps that branch. Each board
refresh deletes the reviews whose merge request was merged or closed on the
forge (one forge call per stored review). Git refuses a worktree with
uncommitted edits, so that review stays until they are gone: Deck never drops
work it did not commit. Tradeoff: fix commits never pushed are lost with the
branch.

**Home sorted by state, not by source (2026-11-03).** Mockups:
https://claude.ai/artifact/EfRod8VSrWG5izieqcw21K (A Flow, B Focus,
C project Overview). The board had one column per source (My MRs, Reviews,
Tickets, Requests), so picking the next thing meant scanning four columns and
ranking them in your head, while Deck already holds a rank per card. Now:
- **Flow** (home): Next, Doing, Waiting, Done today. Next is one list ranked
  across all types; its top card shows in full. (A blue "Do this now" border
  with a line of why was dropped on 2026-11-24: it read like a running
  terminal's border and added nothing the rank does not say.) Doing
  holds cards you started (Claude, IDE or review clicked), cards with a Claude
  session running, and cards where Claude waits for you; 3 at most, and the
  column says so when full. Waiting is today's `blocked` bucket with who and
  since when; snoozed folds into one link. Done today includes what Deck closed
  itself (merged MRs, swept mail). Low value mail (noise, FYI, phishing)
  collapses into one Quick sweep card. Meetings become one line.
- **Focus**: one large Now card with why it ranks first, a small Doing row,
  then the queue. For when you do not want to choose at all.
- **By type**: today's board, kept for triage.
Tradeoff: a Doing state to store and a ranking that works across types
(today scores are only compared inside one lane, see Open questions).

**Four types named by what you do (2026-11-03).** Replies, Reviews, My MRs,
Tasks replace My MRs, Reviews, Tickets, Requests, Todos. The old types mixed
four axes (role on code, tool, channel, who added it), so a Slack ask that
needs real work was both a Request and, once noted, a Todo. Now a Reply is
done when you answered, a Task when the work is done; where it came from is
the provider label on the card (GitLab, GitHub, Jira, Slack, Mail, Deck for
your own notes) and the provider filter. Jira tickets become Tasks. Plural
nouns read as type names; the verbs stay on the buttons (Reply, Review,
Merge). Tradeoff: Haiku decides Reply or Task for each Slack and mail ask
(one more field in the task prompt, still the model's call), and the `Lane`
enum change touches the classifier, Settings, the By type view and goldens.

**The sidebar takes you places, the top bar filters (2026-11-03).** The
sidebar holds Views (Flow, Focus, By type, Activity), Projects (each opens
its project page, logo with platform badge, folder icon without one) and the
provider status at the bottom as today. No filters in it: a list of
checkboxes above a list of links read as one kind of thing. Filtering is one
GitLab style field at the top of Flow and Focus: focus opens a menu before you
type (Project with logos, Type with dots, Provider with labels, a count per
row), a pick becomes a removable token, free text searches titles. It
replaces the search box and the project chips, which would not fit 15
projects. Tradeoff: a token field with autocomplete is more Flutter work than
chips, and a switch is two clicks instead of one. The filter is one provider
shared by Flow and Focus.

**Each card shows project, type and provider (2026-11-03).** Top line:
project logo (16 px, platform badge), type dot and name, ref; the provider as
a small grey label on the right.

**Project Overview page (2026-11-03).** First item of the project sidebar.
What changed (updates by day, each one line with provider and source, new
since your last visit marked) and Facts (Release, Decisions, People, Open
questions; each line says where it came from, a replaced value keeps "(was
...)", any line editable), plus a keyword search over both. Why: you cannot
read everything that happens on a project, but the Slack and mail tasks
already tag each record with its project. Updates cost no extra run: those
tasks add an optional lasting info field, merged MRs come from glab. Updates
are an append only log per project in `state/projects/<id>/`, like the
activity log; one Haiku run rewrites Facts from new updates. Risk: the text
comes from Slack and mail, so a message can carry instructions into Facts.
The writer has no tools, and the page is data wherever it is read.

**Documents on the project Overview (2026-11-05).** A list of the docs,
sheets, dashboards and designs linked to a project, above Facts. The Slack
and mail tasks fill it with a `docs` field ({url, title}) next to `lasting`,
so it costs no extra run; you can also add a link or remove one. Kept in
`state/projects/<id>/docs.json`, one entry per url; a removed one stays in
the file so the same message read again does not bring it back. A separate
file from `overview.json` because the fetch writes docs while a page visit
rewrites Facts. Only `https://` links are kept. Limit: Slack only reads
messages aimed at you, so a link posted in a channel without a mention is
missed; add it by hand. Any Claude session can also add one with the
`add_project_doc` MCP tool, and a fact with `add_project_fact`. A fact added
that way is marked edited, so the facts run keeps it like a line you wrote.

**Claude tells its tab working, blocked or done (2026-11-05).** Silence
alone mixes "asks you" and "finished". Each `claude` a Deck tab starts gets
`--settings cache/claude-hooks.json` and `DECK_TAB=<id>`; its hooks POST
`/tab?id=&state=` on port 4777. UserPromptSubmit, PreToolUse and PostToolUse
mean working (a spinner on the tab and card); a permission or question
Notification, or a PreToolUse of AskUserQuestion or ExitPlanMode, means
blocked (the orange "waits for you" we had); Stop means done, the plain
look. Esc fires no Stop, so a working tab silent for 10 s turns done.
The old rule (3 s of silence means it waits for you) is gone from Deck
tabs: a tab with no hook (another command, Windows) shows only running.
Sessions Deck starts in an outside terminal get the same hooks; with no tab
they report Claude's `session_id`, and the card's session line takes that
state over the transcript's guess (the transcript can not see a permission
prompt). The transcript still gives the title, the last line, closed, and
the state until the first hook (after a Deck restart, say). A finished turn
in the transcript now reads "done", not "waits for you".

**Terminal tabs come back after a restart (2026-11-05).** Each tab that
runs a Claude session we know the id of keeps a restore line
(`claude --resume <id>` plus the flags it started with, never the first
prompt). The list is in `cache/terminals.json`; at start Deck reopens them
with the panel hidden. A tab leaves the list when you close it or the
session ends on its own (exit 0); a kill, as when Deck quits, keeps it.
Card Review and Feedback commands come from Settings with no session id,
so they are not restored rather than started over.

**Talk about a project in the terminal panel (2026-11-03).** "Talk about
<project>" sits in the project sidebar, so every project page has it, with
the running and earlier sessions under it (Show, Resume). It opens a tab in
the existing terminal panel (`TerminalDock`), in the project folder. No
context options: the session gets the Deck tools for the project (overview,
map, MRs, board) and calls them when a question needs them, so full context
costs nothing up front. It replaced a one shot Ask box, because architecture
and feature questions need a conversation and the code.

**Tasks in worktrees, without a ticket (2026-11-13).** "New Task…" (board
sidebar, or a project's) asks a branch name, makes a worktree from origin's
default branch under `<project>/.claude/worktrees/`, where `claude -w` puts
ticket worktrees, and starts Claude there. It never opens the IDE. Deck makes
the worktree itself rather than `claude -w`, so it exists when the list
refreshes. `.claude/worktrees/` goes in `.git/info/exclude`, never in a tracked
file. The Worktrees list comes from `git worktree list` (Deck's review
worktrees left out), nothing is stored; a row goes back to its running tab or
runs `claude --continue` there, since Claude keeps sessions per folder.
Remove keeps the branch.

**Fix commits and Accepts take turns on the branch (2026-11-16).** Every
branch write of a review (Accept's pick, mark_fixed taking a commit off,
Reject) runs under one lock per branch. While Claude works on the review
(session or its terminal), an Accept only records the call: the fix waits
("on the branch when Claude is done") and goes on when the session ends, so
it never lands between Claude's commit and its mark_fixed. mark_fixed takes
any unpushed commit made in the review, not only the tip: the commits above
are replayed on its parent with `git replay` (in memory, nothing checked
out), and the fixes among them follow their new shas. A pushed commit, or
one the commits above need, stays and is recorded as on the branch. Reject
of a pushed fix asks for a revert commit; Deck never force-pushes. A revert
of a buried local fix conflicts exactly when dropping it does (same three
trees), so that case is refused.

**Linked cards, not merged ones (2026-11-16).** A Slack ask about a Jira
ticket and the MR that fixes it stay three cards; each shows the others as
chips (click opens, cross cuts the link). Links are found at 0 tokens from
what a card mentions: Jira keys and MR refs in its title, link and branch
(`DeckCard.refs`), plus `about`, the one ticket or MR Haiku reads a Slack ask
or mail ask is about (no extra run, it already judges the message). Only ids
of cards on the board make a link, so "UTF-8" in a title links nothing. You
link by dragging one card onto another; links you make or cut live in
`state/links.json` per card pair, and a cut link is never found again.
Linking, not grouping: a message about two tickets would glue them into one
group, while as links each ticket just shows it. Tradeoff: the board still
shows three cards for one piece of work. In Flow a card dropped on a column
(not on a card) moves: Doing starts it, Next is Not now or reopen, Done marks
it done (only cards Deck cannot close itself).

**Generated UI only in panels, later.** A GenUI style catalog (Claude fills a
card detail panel from fixed components) fits on demand views. The board stays
fixed: regenerating it would cost a model call per refresh and move things around.

## Background worker flags (from the first spike)

- `--model haiku --disable-slash-commands --tools ToolSearch` plus
  `--allowedTools` with only the read tools of each task. The worker reads
  untrusted Slack and mail text, so no shell and no file tools.
- Keep tool search on: `--tools ""` loads every MCP tool up front ($0.42 a run).
- No `--strict-mcp-config`: it also drops the claude.ai connectors.
- `--permission-mode default`: the user's `auto` mode would otherwise approve
  before Deck is asked. `--permission-prompt-tool mcp__deck__deck_permission`
  routes asks to a banner in the app.
- Code sessions (project info, map, review) use `--permission-mode auto`:
  they run many one-off shell commands that no allowed rule matches, so
  default mode asked for nearly each one. They read your repos and merge
  requests, not mail or Slack, so the auto classifier is the guard there.

## Next

See `BACKLOG.md`.

## Open questions

- Ranking across sources: keep the Work Queue scores, or one formula?
