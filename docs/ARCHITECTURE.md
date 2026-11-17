# Architecture

**claude-code-vscode-notifications** (short name **CCNotify**) is a small, local-only kit for people who run
[Claude Code](https://docs.claude.com/en/docs/claude-code) in the VS Code integrated terminal on macOS:

1. **Popup** (`CCNotify.app`): a translucent card at the top-right that shows Claude's last message rendered as
   Markdown (bold, code, lists, headings, real tables, scroll for long messages) when Claude finishes or needs you.
   Click → jumps to the exact VS Code terminal running that session.
2. **Menu bar** (`CCNotify Sessions.app`): one item and a panel that show every Claude session and its state
   (needs you · wrote to you · thinking), most relevant first. Click a session → same jump; hover → actions and the
   whole last message. An options page sets the icon, the per-session emoji and what the panel shows.
3. **Focus Terminal extension** (`ccnotify.focus-terminal`): tiny VS Code extension that reveals the right terminal.
4. **Sounds per message type** (done · permission · question · agent), configurable.
5. **Status line** (`statusline.py`): optional minimal one-line status for Claude Code.

Nothing leaves the machine. No telemetry. No network calls except the optional market ticker in the status line
(off by default).

---

## Names, paths and ids (single source of truth)

| Thing | Value |
|---|---|
| Install root | `~/.claude/ccnotify/` (override: env `CCNOTIFY_HOME`) |
| Claude config dir | `~/.claude/` (override: env `CLAUDE_CONFIG_DIR`, same as Claude Code) |
| Hook entry point | `~/.claude/ccnotify/bin/notify.sh <event>` |
| Hook logic | `~/.claude/ccnotify/bin/notify.py` |
| Jump to session | `~/.claude/ccnotify/bin/focus_session.py <host-bundle-id> <cwd> [<claude-pid>]` |
| Popup app | `~/.claude/ccnotify/CCNotify.app` (bundle id `io.github.ccnotify.popup`, executable `ccnotify-popup`) |
| Menu bar app | `~/.claude/ccnotify/CCNotify Sessions.app` (bundle id `io.github.ccnotify.sessions`, executable `ccnotify-sessions`) |
| Menu bar LaunchAgent | `~/Library/LaunchAgents/io.github.ccnotify.sessions.plist` |
| VS Code extension id | `ccnotify.focus-terminal` (publisher `ccnotify`, name `focus-terminal`) |
| Config | `~/.claude/ccnotify/config.json` (created from `config.example.json` if missing; all keys optional) |
| State dir | `~/.claude/ccnotify/state/` |
| Popup queue | `state/queue/<uuid>.json` (popup deletes the file after reading it) |
| Active popups (stacking) | `state/active/<session-short-id>__<pid>` containing `"<created-epoch> <height>"` |
| Session states (menu bar) | `state/sessions/<session-id>.json` |
| Context of each session | `state/context/<session-id>.json` → `{"pct", "at"}`; written by the status line (optional), removed with the session |
| Account usage | `state/usage.json` → `{"five_hour": {"pct", "resets_at"}, "seven_day": {…}, "at"}`; written by the status line (optional). Without it the panel has no "Limits" block |
| Menu bar app's own files | `state/menubar/` (0700, files 0600), written only by the menu bar app: `pins/<safe id>` · `reminders/<safe id>.json` · `options.json` · `emoji-auto.json` · `emoji-chosen.json` (see [Menu bar app](#menu-bar-app)) |
| Emoji pictures | `assets/emoji/<family>/*.png` in the repo (Fluent Emoji, MIT, see `assets/emoji/LICENSE`); `scripts/build.sh` copies them to `CCNotify Sessions.app/Contents/Resources/emoji/` |
| Focus request | `state/focus-request.json` → `{"at": <epoch seconds>, "pids": [<claude pid>, <its parents>...]}`; for a background session also `"job"`, `"cwd"`, `"claude"` (path of the command, or `""`) and `"project"` (label for the terminal tab; omitted for the home folder) |
| Focus claim | `state/focus-<at>.claim` (empty file; created with `wx` by the one extension window that handles a request; removed after 60 s) |
| Decision log (no message text) | `state/ccnotify.log` (rotated at 1 MB) |
| Statusline | `~/.claude/ccnotify/statusline/statusline.py` |
| Statusline cache | `~/.claude/ccnotify/state/statusline/` |

### Hook events (argument to `notify.sh`)

| Claude Code hook | Argument | What happens |
|---|---|---|
| `Stop` | `stop` | Popup "done" (unless background agents/workflows are still running in that session) |
| `Notification` | `notification` | Popup only for `permission_prompt` → kind `permission`, `elicitation_*` → kind `question`, `agent_needs_input` → kind `agent`. `idle_prompt` shows no popup: it only repairs a row left on "thinking" (see *Hooks*). Everything else is ignored. |
| `UserPromptSubmit` | `prompt` | Menu bar: session → thinking. No popup. |
| `SessionStart` | `session-start` | Menu bar: drop a previous session of the same Claude process (i.e. `/clear`). Creates no row. |
| `SessionEnd` | `session-end` | Menu bar: remove session. |

All hooks are registered with `"async": true, "timeout": 10` so they never slow Claude Code down.

### Message kinds

`done`, `permission`, `question`, `agent`. Each kind has its own sound and its own small visual cue in the popup
(an SF Symbol + a localized label next to the project name, tinted with a neutral accent — **never** a colored
stripe on one side of the card).

---

## Config (`config.json`) — all keys optional

```jsonc
{
  "language": "auto",                 // "auto" | "en" | "es". auto = macOS preferred language starts with "es" → es, else en
  "popup": {
    "enabled": true,
    "seconds": 60,                    // auto-dismiss; pauses while hovered or while the user is idle > 90 s
    "width": 460,
    "max_height_ratio": 0.8,          // beyond this fraction of the screen height the text scrolls
    "max_stacked": 4
  },
  "sounds": {                         // "sound": macOS system sound name (see /System/Library/Sounds),
                                      //          an absolute path to an audio file, or "" for silence
    "done":       { "sound": "Glass",     "volume": 0.5, "only_when_away": true },
    "permission": { "sound": "Submarine", "volume": 0.8 },
    "question":   { "sound": "Ping",      "volume": 0.8 },
    "agent":      { "sound": "Purr",      "volume": 0.7 }
  },
  "quiet_hours": { "enabled": false, "from": "22:00", "to": "07:00" },   // sounds muted, popups still shown
  "events": { "done": true, "permission": true, "question": true, "agent": true },  // turn popups on/off per kind
  "statusline": { },                  // see docs/statusline.md
  "project_names": { }                // folder name → label, e.g. {"long-repository-name": "repo"}
}
```

Project label (popup title, menu bar, status line, terminal tab): the folder name of the session's cwd, where a
Claude Code worktree (`<project>/.claude/worktrees/<name>`) stands for its `<project>`, trailing slash dropped. The
home folder shows the localized "Home" label (never the macOS account name). Then `project_names[<folder name>]`
replaces it when it is a non-empty string; anything else in `project_names` is ignored. The rule lives in
`notify.py`, `statusline.py` and `focus_session.py`; keep them in step.

`only_when_away`: play the sound only when the app hosting the session (e.g. VS Code) is not the frontmost app.

## Popup input JSON (written by `notify.py`)

```json
{
  "title": "my-project", "kind": "done", "text": "markdown…",
  "id": "abc123def456", "session": "<full session id>", "host": "com.microsoft.VSCode",
  "focus": {"host": "com.microsoft.VSCode", "cwd": "/path", "pid": 1234, "job": "<background id, optional>"},
  "transcript": "/path/x.jsonl", "transcript_size": 123456, "event_at": <epoch>,
  "language": "en", "sound": "Glass", "volume": 0.5, "only_when_away": true,
  "seconds": 60, "width": 460, "max_height_ratio": 0.6, "max_stacked": 4, "compact_lines": 2,
  "sticky_needs_you": true, "font_size": 13, "private": false, "style": "color"
}
```

The popup must work with only `title`, `kind`, `text` (everything else has defaults). `text` is capped at
20,000 characters by `notify.py`.

## Session state JSON (`state/sessions/<id>.json`, written by `notify.py`, read by the menu bar)

```json
{
  "session": "<full id>", "project": "my-project", "cwd": "/path", "transcript": "/path/x.jsonl",
  "host": "com.microsoft.VSCode", "focus": {"host": "…", "cwd": "/path", "pid": 1234, "job": "<optional>"},
  "pid": 1234, "state": "thinking" | "needs" | "wrote", "kind": "permission" | "question" (only while "needs"),
  "since": <epoch>, "updated_at": <epoch>,
  "summary": "one-line summary", "request": "user's last prompt (short)", "tasks": 0,
  "turn_started_at": <epoch>, "done_text": "…", "done_at": <epoch>
}
```

`pid` is the session's own Claude Code process (not a shared ancestor): the menu bar drops a session when that
process is gone. "Seen" is not stored here: a session is seen when `state/seen/<id>` holds an epoch >= `since`.
`state/ended/<id>` is a tombstone written by `SessionEnd` so a late async hook cannot bring the session back.

## Menu bar app

`src/menubar/main.swift` (one file, AppKit, macOS 12+). The status item is an SF Symbol (a template, so the bar paints
it) plus, when sessions wait for you, one number. A click opens an `NSPopover` with one list of rows, most relevant
first: pinned, needs you (oldest first), finished and unread, reminder pending, working, read. Everything is hand drawn;
dynamic colors resolve on every redraw, so light and dark follow the system.

- **Row:** `[emoji] state word · project · "2 agents · ctx 62 % · 3 min" · [pin]`. The state word and the colors come
  from the *tone* of the row (`permission`/`question` from `kind`, `needs`, `finished`, `reminded`, `working`, `read`);
  `popup.style: "mono"` makes all of it grayscale (the emoji too).
- **Hover:** a mouse clock (every 30 ms, not tracking areas, which die with each rebuild) opens a row after 180 ms
  (Go to chat · Remind me · Mark as read · Pin) and, after 600 ms of rest, shows a bubble with the whole last message
  beside the panel. `popup.private` keeps message text out of everything, so there is no bubble then.
- **Live state:** besides the hooks it follows each session's transcript in memory (permission approved, request
  interrupted, you typed) so a state does not stay stale when no hook fires. It never writes the session files.
- **Reminders:** `state/menubar/reminders/<safe id>.json` `{"at", "since"}`. When one comes due the usual popup is shown
  (a JSON in `state/queue/` and `open -n -g CCNotify.app`); it is dropped when the session changes state or ends.
- **Limits:** the "Limits" block comes from `state/usage.json`; the "ctx NN %" of a row from `state/context/<id>.json`.
  Both are written by the status line, so without it there is neither.
- **Options page** (the gear in the footer): the icon of the status item (a line of SF Symbols), emoji on/off and
  the family, and three checkboxes (bubble, usage, context). Saved to `state/menubar/options.json`, never to
  `config.json`: `{"icon", "emoji_theme": "<family>" | "none", "bubble", "usage", "context"}`. Unknown keys are kept; a
  missing or unreadable file means the defaults (`bubble.left.and.bubble.right`, `nature`, everything on).
- **Emoji:** families are the folders of `Contents/Resources/emoji/` (`nature`, `bugs`, `music`, `cozy`, `adventure`,
  `animals`, `fruits`, `gems`, `colors`; any other folder with PNGs is offered too). A session gets one from the chosen
  family and keeps it (`state/menubar/emoji-auto.json` `{"family", "assigned": {"<safe id>": "<name>.png"}}`): the file
  its id hashes to (FNV-1a) or, if another open session has it, the next free one (a repeat only if none is free).
  Clicking the emoji of a row opens a picker with every family; the choice goes to `emoji-chosen.json`
  `{"<safe id>": "<family>/<name>.png"}` and rules over the automatic one (which steps aside for it). "Automatic" removes
  it. Entries of ended sessions are dropped when their session file is gone. Changing the family gives everyone a new
  emoji; "none" shows no emoji column.
- **Ownership:** the app writes only under `state/menubar/` (atomic temp file + rename, 0600 in a 0700 folder). Deleting
  that folder resets pins, reminders, options and emoji.

Test hooks of the app (inert unless set; all read the environment, none touches a real install when `CCNOTIFY_HOME`
points elsewhere):

| Variable | Effect |
|---|---|
| `CCNOTIFY_TEST_ORDER=1` | Print the session ids in list order and quit. |
| `CCNOTIFY_TEST_BAR=1` | Print `<number>\t<tooltip>` (what the bar shows) and quit. |
| `CCNOTIFY_TEST_USAGE=1` | Print one line per row of the "Limits" block and quit (`CCNOTIFY_TEST_NOW=<epoch>`, `TZ=…`). |
| `CCNOTIFY_TEST_EMOJI=1` | Print `<id>\t<family>/<name>.png\tmanual\|auto` for each session and quit. |
| `CCNOTIFY_TEST_OPTIONS=<json>` | Save those keys through the options page's code path, print `options.json` and quit. |
| `CCNOTIFY_TEST_CHOOSE=<id>=<family>/<name>.png` | Save that session's emoji by hand (empty value removes it) and quit. |
| `CCNOTIFY_TEST_REMIND=<id>` / `CCNOTIFY_TEST_MINUTES_AS_SECONDS=1` | Set a "2 min" reminder, let the clock run 12 s, quit; minutes last seconds. |
| `CCNOTIFY_TEST_MOUSE=<id>` | Move the real cursor over a row and away, noting what is open (the 180 ms and 600 ms timings). |
| `CCNOTIFY_TEST_NAV=<id>` | Open the panel and do what the clicks do (options page, switches, icon, emoji picker), noting each step. |
| `CCNOTIFY_OPEN_MENU=1` | Open the panel after a second. |
| `CCNOTIFY_CAPTURE_MENU=<png>` | Open the panel, grab its window (no Screen Recording permission needed) over the status item and quit. With `CCNOTIFY_THEME=light\|dark`, `CCNOTIFY_CAPTURE_SCALE`, and what to show: `CCNOTIFY_CAPTURE_OPEN=<id>`, `CCNOTIFY_CAPTURE_BUBBLE=<id>`, `CCNOTIFY_CAPTURE_REMIND=<id>`, `CCNOTIFY_CAPTURE_PICKER=<id>`, `CCNOTIFY_CAPTURE_OPTIONS=1`, `CCNOTIFY_CAPTURE_ALL_FAMILIES=1`. |
| `CCNOTIFY_EMOJI_DIR=<folder>` | Read the emoji families from there instead of the app bundle. |

`tests/render/render_menubar.sh` uses the capture hooks (with fictional sessions) to make `docs/img/menubar-*.png`.

## Supported editors

`host` comes from the hook's `__CFBundleIdentifier` environment variable. Known values: `com.microsoft.VSCode`,
`com.microsoft.VSCodeInsiders`, `com.vscodium`, `com.todesktop.230313mzl4w4u92` (Cursor), `com.exafunction.windsurf`.
VS Code–family hosts get the folder-focus + terminal-focus behavior; any other host (e.g. Terminal, iTerm2) is just
brought to the front.

## Branding / legal

- Do **not** ship Anthropic's logo or copy any icon from `Claude.app`. The popup draws a neutral SF Symbol.
  If `~/.claude/ccnotify/logo.png` exists, it is used instead.
- README states the project is unofficial and not affiliated with Anthropic.
- License: MIT.

## Test hooks (no Screen Recording permission needed)

- `CCNOTIFY_CAPTURE=<file.png>`: popup renders, saves a PNG of itself (`cacheDisplay`, without blur) and quits.
- `CCNOTIFY_THEME=light|dark`: force appearance.
- `CCNOTIFY_COMPACT=1`: render the compact version (`compact_lines`) and don't re-stack.

## Requirements

macOS 12+, Xcode Command Line Tools (`swiftc`, `python3`, `git`). Apps are built from source on the user's machine by
`install.sh` (no prebuilt binaries → no Gatekeeper/notarization issues; ad-hoc codesign).

---

## v1 design decisions (from an independent review)

These refine everything above. When in doubt, this section wins.

### Popup
- **Kind cue in the header:** `[app icon] project · [SF Symbol] Label`. Symbols: done `checkmark.circle`, permission
  `hand.raised`, question `questionmark.bubble`, agent `person.crop.circle.badge.questionmark` (fall back to
  `questionmark.circle` if a symbol is missing on macOS 12). Labels (en/es): Done/Terminó · Needs permission/Pide permiso ·
  Question/Pregunta · Agent asks/Un agente pregunta. "Needs you" kinds (permission, question, agent) tint the symbol and
  label with the attention color (same orange family as the menu bar) **and** draw a thin *full* border in that tint.
  Never a one-sided stripe/bar. No big numbers.
- **Sticky "needs you":** permission/question/agent popups do not auto-dismiss; they close when the conversation moves on
  (transcript grows with a new assistant/user message), on click, or ✕. Timer applies to `done` only.
  Config `popup.sticky_needs_you` (default true).
- **Height:** default `max_height_ratio` 0.6; beyond it the body scrolls (wheel/trackpad; overlay scroller flashes on open).
- **Screen:** chosen once at creation = the screen containing the mouse pointer; stacking computed per that screen.
- **Live appearance:** colors are dynamic (`NSColor(name:dynamicProvider:)`) so light/dark switches live.
- **Accessibility:** if `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` → opaque background; if
  `…ShouldIncreaseContrast` → stronger border; if `…ShouldReduceMotion` → no slide animations (fade only, or none).
  Post `NSAccessibility.post(element:notification: .announcementRequested, userInfo: [.announcement: "<project>: <label>. <first line>", .priority: high])`.
  Font size from `popup.font_size` (default 13).
- **Privacy:** `panel.sharingType = .none`. `popup.private` (default false): show only project + kind label, no message text.
- **Stack safety:** active files are `state/active/<id>__<pid>`; before `kill(pid, SIGTERM)` verify with `proc_pidpath`
  that the pid's executable is our popup binary; otherwise just delete the stale file. Ignore stale files whose pid
  is dead or not ours when computing the stack.
- **Click / jump:** never run a shell string. Popup JSON carries `focus: {host, cwd, pid}`; the app runs
  `/usr/bin/env python3 <CCNOTIFY_HOME>/bin/focus_session.py --host <h> --cwd <c> [--pid <p>]` via `Process` with argv.
- **Seen markers:** opening/clicking a popup writes `state/seen/<session-id>` with the epoch (no read-modify-write of the
  session JSON). The menu bar treats a session as seen if `seen >= since`.
- **Transcript baseline:** popup JSON carries `transcript_size` (bytes at hook time) and `event_at`; the popup uses that
  as the baseline to detect "conversation moved on", instead of measuring itself ~1 s later.
- **Sound:** popup plays it (it knows whether the host app is frontmost) but first checks `state/last-sound` (epoch):
  at most one sound every 3 s across all popups (update the file when playing). `sound` may be a name (NSSound(named:)
  also finds files in `~/Library/Sounds`) or an absolute path; `""` = silent.

### Styles (added after visual review)
- `popup.style`: `"color"` (the default; one hue per kind — done green, permission orange, question blue, agent
  violet — with a subtle full-surface tint and a thin full border), `"neutral"` (neutral card; needs-you kinds in the
  attention tint),
  `"mono"` (grayscale only; needs-you kinds use a filled symbol, semibold label and a stronger full border).
  Any other value, or a missing key, means `"color"` (validated in `hooks/notify.py`, and again in the popup app).
- `popup.compact_lines` (default 2): lines shown by older popups in the stack.
- Layout: header row (small icon · project · kind) separated from the body by a hairline rule; the body uses the
  full card width.

### Hooks (`notify.py`)
- **Claude PID detection:** walk parents; match `comm == "claude"` OR (`comm` is `node`/`bun` and the full args contain
  `claude`). Compute once per hook run.
- **Ordering:** every session-state write includes `updated_at` (= hook event time); writes take an exclusive `fcntl.flock`
  on `state/sessions/.lock` and skip if the stored `updated_at` is newer. Fixes async-hook races (e.g. a slow `stop`
  finishing after a fast `prompt`).
- **One row per conversation:** a row is created by the session's own first `prompt`, `stop` or notification, never
  by `SessionStart` (a session that is never used, or the agent view itself, would only clutter the menu). The
  agent view's `agent_needs_input` relay never writes a row for the agent view's own session id: it sets the
  job's own row (the one whose `focus.job` is that job and whose transcript exists) to "needs" with the question,
  keeping its other fields, and the popup carries that session id. If the job has no row, the popup is still shown
  and no row is written.
- **Stuck "thinking" repair:** if a `Stop` never arrives, the row would say "thinking" forever. Claude Code sends
  an `idle_prompt` notification about a minute after it goes idle; when the row is "thinking" and no background
  tasks are running, `notify.py` turns it into "wrote": unseen, with the last assistant text as summary, if the
  transcript has an assistant entry newer than the row's `since`; otherwise (e.g. a local slash command) marked
  seen with the old summary. No popup, no sound. In any other case the notification is ignored.
- **Fragile parsing isolated:** everything that depends on undocumented transcript/notification text (background-agent
  detection, "needs your input:" parsing, "permission to use" phrasing, interrupt markers) lives in
  `hooks/ccnotify_transcript.py` with unit tests on small sample transcripts in `tests/fixtures/`. Prefer documented hook
  fields (`notification_type`, `notification_data`, `last_assistant_message`, `stop_hook_active`) when present.
- **Done sound rules:** silent if the turn was shorter than `sounds.done.min_turn_seconds` (default 15; turn start =
  last `prompt` event time for that session) — the popup still shows. Quiet hours → `sound: ""`.
- **Housekeeping each run:** delete `state/queue/*.json` older than 1 h; dirs created 0700, files written 0600; log is
  append-only with rotation at 1 MB; never log message text.
- **Fallback:** if `CCNotify.app` isn't installed, fall back to `osascript -e 'display notification …'` (no third-party deps).

### VS Code extension
- Identify its own editor: map `vscode.env.uriScheme` → bundle id (`vscode` → `com.microsoft.VSCode`,
  `vscode-insiders` → `com.microsoft.VSCodeInsiders`, `vscodium` → `com.vscodium`, `cursor` →
  `com.todesktop.230313mzl4w4u92`, `windsurf` → `com.exafunction.windsurf`), and raise its window with
  `open -b <that id> <workspaceFile or first folder>`.
- Ignore requests older than 10 s; poll `state/focus-request.json` every 300 ms with `fs.watchFile`.
- Background sessions (`claude --bg`) have no terminal of their own. For a request with `job`, the window that owns
  the main session's terminal shows the terminal that is running `claude attach <job>` **right now** or, if there is
  none, opens a new one; it never types into the main session's terminal. A terminal is never reused by its name:
  pressing ← inside `claude attach` turns it into the agent view, where any other conversation can be opened, while
  the tab keeps its old name. Each click asks `ps` what every terminal is running (its own process or a command
  started from its shell, at any depth). Terminals that moved on are left open.
- Sessions hosted by the background daemon (newer Claude Code): the pid chain is `[session, pty host, daemon]` with no
  terminal shell, so no window owns the request, and the user browses sessions in the agent view (`claude agents`) in
  some terminal. For a request with a valid `job` and no owner, every window computes a priority: 1 it has a terminal
  running `claude attach <job>`; 2 it has a terminal running the agent view; 3 a workspace folder (file scheme, not the
  home folder) contains the session's project folder (`cwd` cut at `/.claude/worktrees/`); 4 anything else. It waits
  `priority × 600 ms` and then claims the request by creating `focus-<at>.claim` (`<at>` = the request's `at`, digits
  and dots only) in the same `state/` folder with the open flag `wx`. Only the first creation succeeds and acts (show or
  create the `claude attach <job>` terminal, raise the window); `EEXIST` means another window won and this one does
  nothing; any other error means proceed. The owner window (priority 0) claims at once. Claim files older than 60 s are
  removed on each claim. Without a `job` and without an owner the request is ignored, as before.
- "`<name>` needs your input" comes from the agent view, a session of its own with no job id. `notify.py` looks the
  name up in `<claude config>/jobs/<id>/state.json` (`name`; newest `updatedAt` wins) and puts that id in `focus.job`,
  so the click opens the session that asked. The same id drops the popup when that job announced its own "done"
  within 120 s (the agent view rewords the question, so the text comparison alone misses it).
- Sticky "needs you" popups start their countdown once a tool result appears in the transcript after them (you
  answered); they close at once when Claude writes again or you type.

### Install
- `install.sh` (idempotent): checks macOS ≥ 12, `swiftc`, `python3`; copies to `$CCNOTIFY_HOME`; builds both apps
  (`-target <arch>-apple-macos12`; `--universal` builds arm64+x86_64 and `lipo`s them); writes `config.json` only if
  missing; **merges** hooks into `$CLAUDE_CONFIG_DIR/settings.json` with a timestamped backup, never removing other
  hooks (ours are recognized by the substring `ccnotify/bin/notify.sh`); `--statusline` also sets `statusLine` (refuses
  to overwrite a different one unless `--force`); creates + loads the LaunchAgent; installs the extension into every
  editor CLI it finds (`code`, `code-insiders`, `cursor`, `codium`, `windsurf`, also looked up inside the app bundles).
  `--dry-run` prints what it would do. Honors `CCNOTIFY_HOME` / `CLAUDE_CONFIG_DIR` (tests install into a temp dir).
- `uninstall.sh` removes exactly what install added (hooks entries, statusLine only if it is ours, LaunchAgent, apps,
  extension) and `--purge` deletes `$CCNOTIFY_HOME` including state. Without `--purge`, `state/` (and so
  `state/menubar/`: pins, options, emoji) is kept, like the rest of the state.

### Later (not v1)
Package as a Claude Code plugin (`hooks/hooks.json` + `${CLAUDE_PLUGIN_ROOT}`); single long-running process that draws
all popups; global hotkey; per-project mute and "mute 1 h" from the menu bar.
