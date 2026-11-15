#!/bin/bash
# CCNotify installer (idempotent). Requires macOS 12+, python3 and (to build the apps) swiftc.
#
#   ./install.sh [--dry-run] [--statusline] [--force] [--universal]
#                [--skip-build] [--skip-launchagent] [--skip-extension]
#
#   --dry-run          print what would be done, change nothing
#   --statusline       also set Claude Code's `statusLine` (refuses to replace a different one unless --force)
#   --force            allow replacing an existing, different statusLine
#   --universal        build the apps for arm64 + x86_64 (default: this machine's architecture)
#   --skip-build       do not build the apps (testing)
#   --skip-launchagent do not create/load the menu bar LaunchAgent (no menu bar icon)
#   --skip-extension   do not install the VS Code extension (a click then only raises the editor)
#
# Environment: CCNOTIFY_HOME (default <claude config dir>/ccnotify), CLAUDE_CONFIG_DIR (default ~/.claude),
# CCNOTIFY_LAUNCHAGENTS_DIR (default ~/Library/LaunchAgents).
# Nothing leaves this machine; no network access.

set -u

SRC="$(cd "$(dirname "$0")" && pwd)"
DRY=0
STATUSLINE=0
FORCE=0
UNIVERSAL=0
SKIP_BUILD=0
SKIP_LA=0
SKIP_EXT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --statusline) STATUSLINE=1 ;;
    --force) FORCE=1 ;;
    --universal) UNIVERSAL=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --skip-launchagent) SKIP_LA=1 ;;
    --skip-extension) SKIP_EXT=1 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CCHOME="${CCNOTIFY_HOME:-$CLAUDE_DIR/ccnotify}"
SETTINGS="$CLAUDE_DIR/settings.json"
LA_DIR="${CCNOTIFY_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
LA_LABEL="io.github.ccnotify.sessions"
LA_PLIST="$LA_DIR/$LA_LABEL.plist"

say() { echo "$*"; }
step() { if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else echo "$*"; fi; }
warn() { echo "warning: $*" >&2; }
die() { echo "error: $*" >&2; exit 1; }

# The home path ends up inside a shell command in settings.json: keep it free of shell metacharacters.
case "$CCHOME" in
  *\"*|*\$*|*\`*|*\\*) die "CCNOTIFY_HOME contains a character that is not supported: $CCHOME" ;;
esac

# --------------------------------------------------------------------------- requirements
[ "$(uname -s)" = "Darwin" ] || die "CCNotify needs macOS."
MACOS_MAJOR="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
case "$MACOS_MAJOR" in
  ''|*[!0-9]*) die "could not read the macOS version." ;;
esac
[ "$MACOS_MAJOR" -ge 12 ] || die "macOS 12 or newer is required (found $(sw_vers -productVersion))."
command -v python3 >/dev/null 2>&1 || die "python3 not found. Install the Xcode Command Line Tools: xcode-select --install"
if [ "$SKIP_BUILD" = 0 ] && [ "$DRY" = 0 ]; then
  command -v swiftc >/dev/null 2>&1 || die "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install"
fi

say "CCNotify install"
say "  source:          $SRC"
say "  install dir:     $CCHOME"
say "  Claude settings: $SETTINGS"

# --------------------------------------------------------------------------- files
mkdir_private() {
  if [ "$DRY" = 1 ]; then
    [ -d "$1" ] || step "create directory $1 (0700)"
  else
    if ! { mkdir -p "$1" && chmod 700 "$1"; }; then die "cannot create $1"; fi
  fi
}

put() { # put <source> <destination> <mode>
  if [ "$DRY" = 1 ]; then
    step "copy $1 -> $2"
  elif [ ! "$1" -ef "$2" ]; then
    install -m "$3" "$1" "$2" || die "cannot copy $1 to $2"
  fi
}

mkdir_private "$CCHOME"
for d in bin statusline vscode-extension state state/queue state/sessions state/seen state/ended; do
  mkdir_private "$CCHOME/$d"
done

for f in notify.sh notify.py focus_session.py; do put "$SRC/hooks/$f" "$CCHOME/bin/$f" 755; done
put "$SRC/hooks/ccnotify_transcript.py" "$CCHOME/bin/ccnotify_transcript.py" 644

if [ -d "$SRC/statusline" ]; then
  for f in "$SRC"/statusline/*; do
    [ -f "$f" ] || continue
    case "$f" in
      *.py|*.sh) put "$f" "$CCHOME/statusline/$(basename "$f")" 755 ;;
      *) put "$f" "$CCHOME/statusline/$(basename "$f")" 644 ;;
    esac
  done
else
  warn "statusline/ not found in the source; skipping it"
fi

for f in package.json extension.js package.py; do put "$SRC/vscode-extension/$f" "$CCHOME/vscode-extension/$f" 644; done
put "$SRC/config.example.json" "$CCHOME/config.example.json" 644
[ -f "$SRC/LICENSE" ] && put "$SRC/LICENSE" "$CCHOME/LICENSE" 644

if [ -f "$CCHOME/config.json" ]; then
  say "config.json already exists: left untouched"
elif [ "$DRY" = 1 ]; then
  step "create $CCHOME/config.json from config.example.json (0600)"
else
  install -m 600 "$SRC/config.example.json" "$CCHOME/config.json" || die "cannot create config.json"
  say "created $CCHOME/config.json"
fi

# --------------------------------------------------------------------------- apps
if [ "$SKIP_BUILD" = 1 ]; then
  say "skipping the app build (--skip-build)"
else
  BUILD="$SRC/scripts/build.sh"
  [ -f "$BUILD" ] || die "scripts/build.sh not found"
  UNI=""
  [ "$UNIVERSAL" = 1 ] && UNI="--universal"
  if [ "$DRY" = 1 ]; then
    step "build CCNotify.app and 'CCNotify Sessions.app' into $CCHOME: bash scripts/build.sh $CCHOME $UNI"
  else
    say "building the apps (takes a minute)..."
    # shellcheck disable=SC2086
    bash "$BUILD" "$CCHOME" $UNI || die "the app build failed"
  fi
fi

# --------------------------------------------------------------------------- Claude Code settings
if [ "$DRY" = 1 ]; then
  step "merge hooks into $SETTINGS (timestamped backup first; other hooks are kept)"
fi
CC_SETTINGS="$SETTINGS" CC_HOME="$CCHOME" CC_DRY="$DRY" CC_STATUSLINE="$STATUSLINE" CC_FORCE="$FORCE" \
python3 - <<'PY' || die "could not update $SETTINGS"
import json, os, shlex, shutil, sys, time

settings = os.environ["CC_SETTINGS"]
home = os.environ["CC_HOME"]
dry = os.environ["CC_DRY"] == "1"
want_statusline = os.environ["CC_STATUSLINE"] == "1"
force = os.environ["CC_FORCE"] == "1"

EVENTS = [("Stop", "stop"), ("Notification", "notification"), ("UserPromptSubmit", "prompt"),
          ("SessionStart", "session-start"), ("SessionEnd", "session-end")]
notify = home + "/bin/notify.sh"
statusline = home + "/statusline/statusline.py"


def ours_hook(command):
    return "ccnotify/bin/notify.sh" in command or notify in command


def ours_statusline(command):
    return "ccnotify/statusline/statusline.py" in command or statusline in command


data = {}
if os.path.exists(settings):
    try:
        with open(settings, encoding="utf-8") as f:
            data = json.load(f)
    except ValueError as exc:
        sys.exit("%s is not valid JSON (%s); fix it first, nothing was changed." % (settings, exc))
    if not isinstance(data, dict):
        sys.exit("%s is not a JSON object; nothing was changed." % settings)
before = json.dumps(data, sort_keys=True)

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    sys.exit("'hooks' in %s is not an object; nothing was changed." % settings)
for event, arg in EVENTS:
    wanted = {"type": "command", "command": '"%s" %s' % (notify, arg), "async": True, "timeout": 10}
    groups = hooks.setdefault(event, [])
    if not isinstance(groups, list):
        sys.exit("hooks.%s in %s is not a list; nothing was changed." % (event, settings))
    found = False
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
            continue
        kept = []
        for hook in group["hooks"]:
            if isinstance(hook, dict) and ours_hook(str(hook.get("command", ""))):
                if not found:
                    kept.append(wanted)
                    found = True
            else:
                kept.append(hook)
        group["hooks"] = kept
    if not found:
        groups.append({"hooks": [wanted]})

notes = []
if want_statusline:
    current = data.get("statusLine")
    command = shlex.quote(statusline)
    wanted_line = {"type": "command", "command": command, "refreshInterval": 60}
    if current is None or force or (isinstance(current, dict) and ours_statusline(str(current.get("command", "")))):
        data["statusLine"] = wanted_line
    else:
        notes.append("statusLine NOT changed: a different one is already set (use --force to replace it).")

after = json.dumps(data, sort_keys=True)
if after == before:
    print("settings.json already up to date: no changes")
elif dry:
    print("[dry-run] would write hooks %s%s" % (", ".join(a for _, a in EVENTS),
          " and statusLine" if want_statusline and data.get("statusLine") else "") + " to " + settings)
else:
    os.makedirs(os.path.dirname(settings), exist_ok=True)
    mode = 0o600
    if os.path.exists(settings):
        mode = os.stat(settings).st_mode & 0o777
        backup = "%s.ccnotify-backup-%s" % (settings, time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(settings, backup)
        print("backup: " + backup)
    tmp = "%s.%d.tmp" % (settings, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, settings)
    print("hooks updated in " + settings)
for note in notes:
    print(note)
PY

# --------------------------------------------------------------------------- LaunchAgent (menu bar)
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

if [ "$SKIP_LA" = 1 ]; then
  say "skipping the LaunchAgent (--skip-launchagent)"
else
  SESSIONS_BIN="$CCHOME/CCNotify Sessions.app/Contents/MacOS/ccnotify-sessions"
  if [ "$DRY" = 0 ] && [ ! -x "$SESSIONS_BIN" ]; then
    warn "$SESSIONS_BIN not found; not creating the LaunchAgent"
  else
    step "write $LA_PLIST and load it (menu bar app starts at login)"
    if [ "$DRY" = 0 ]; then
      mkdir -p "$LA_DIR" || die "cannot create $LA_DIR"
      {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0">'
        echo '<dict>'
        echo "  <key>Label</key><string>$LA_LABEL</string>"
        echo '  <key>ProgramArguments</key>'
        echo "  <array><string>$(xml_escape "$SESSIONS_BIN")</string></array>"
        echo '  <key>EnvironmentVariables</key>'
        echo "  <dict><key>CCNOTIFY_HOME</key><string>$(xml_escape "$CCHOME")</string></dict>"
        echo '  <key>RunAtLoad</key><true/>'
        echo '  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>'
        echo '  <key>ProcessType</key><string>Interactive</string>'
        echo '</dict>'
        echo '</plist>'
      } > "$LA_PLIST" || die "cannot write $LA_PLIST"
      chmod 644 "$LA_PLIST"
      launchctl bootout "gui/$(id -u)/$LA_LABEL" >/dev/null 2>&1
      launchctl bootstrap "gui/$(id -u)" "$LA_PLIST" >/dev/null 2>&1 || warn "launchctl could not load $LA_PLIST (it will start at your next login)"
    fi
  fi
fi

# --------------------------------------------------------------------------- VS Code extension
editor_clis() {
  # name|path-inside-the-app-bundle
  while IFS='|' read -r name rel; do
    found="$(command -v "$name" 2>/dev/null)"
    if [ -z "$found" ]; then
      for root in /Applications "$HOME/Applications"; do
        if [ -x "$root/$rel" ]; then found="$root/$rel"; break; fi
      done
    fi
    [ -n "$found" ] && echo "$found"
  done <<'EDITORS'
code|Visual Studio Code.app/Contents/Resources/app/bin/code
code-insiders|Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code-insiders
cursor|Cursor.app/Contents/Resources/app/bin/cursor
codium|VSCodium.app/Contents/Resources/app/bin/codium
windsurf|Windsurf.app/Contents/Resources/app/bin/windsurf
EDITORS
}

if [ "$SKIP_EXT" = 1 ]; then
  say "skipping the VS Code extension (--skip-extension)"
else
  CLIS="$(editor_clis)"
  if [ -z "$CLIS" ]; then
    say "no VS Code-family editor found: extension not installed (the popup still brings the editor forward)"
  elif [ "$DRY" = 1 ]; then
    echo "$CLIS" | while IFS= read -r cli; do
      step "install ccnotify.focus-terminal with $cli"
    done
  else
    VSIX_DIR="$(mktemp -d)" || die "cannot create a temp dir"
    VSIX="$VSIX_DIR/ccnotify-focus-terminal.vsix"
    if python3 "$SRC/vscode-extension/package.py" --out "$VSIX" >/dev/null; then
      echo "$CLIS" | while IFS= read -r cli; do
        if "$cli" --install-extension "$VSIX" --force >/dev/null 2>&1; then
          say "extension installed with $cli"
        else
          warn "could not install the extension with $cli"
        fi
      done
    else
      warn "could not build the extension package"
    fi
    rm -rf "$VSIX_DIR"
  fi
fi

say ""
if [ "$DRY" = 1 ]; then
  say "Dry run finished: nothing was changed."
else
  say "Done. Start a new Claude Code session (and reload your editor windows) so the hooks and the extension load."
  say "Edit $CCHOME/config.json to change sounds, language and popup behavior."
fi
