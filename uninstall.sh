#!/bin/bash
# CCNotify uninstaller: removes exactly what install.sh added.
#
#   ./uninstall.sh [--dry-run] [--purge] [--skip-launchagent] [--skip-extension]
#
#   --dry-run          print what would be done, change nothing
#   --purge            also delete the whole install dir, including config.json and state/
#   --skip-launchagent do not touch the menu bar LaunchAgent or running apps (testing)
#   --skip-extension   do not uninstall the VS Code extension (testing)
#
# Removes: our hook entries in settings.json (identified by "ccnotify/bin/notify.sh"; other hooks stay),
# the statusLine only if it is ours, the LaunchAgent, the apps, the program files and the extension.
# config.json and state/ are kept unless --purge. Environment: CCNOTIFY_HOME, CLAUDE_CONFIG_DIR,
# CCNOTIFY_LAUNCHAGENTS_DIR (same meaning as in install.sh).

set -u

DRY=0
PURGE=0
SKIP_LA=0
SKIP_EXT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --purge) PURGE=1 ;;
    --skip-launchagent) SKIP_LA=1 ;;
    --skip-extension) SKIP_EXT=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "uninstall.sh: unknown option: $1" >&2; exit 2 ;;
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

command -v python3 >/dev/null 2>&1 || die "python3 not found."
case "$CCHOME" in
  ''|/|"$HOME") die "refusing to work on CCNOTIFY_HOME='$CCHOME'" ;;
esac

say "CCNotify uninstall"
say "  install dir:     $CCHOME"
say "  Claude settings: $SETTINGS"

# --------------------------------------------------------------------------- settings.json
if [ -f "$SETTINGS" ]; then
  CC_SETTINGS="$SETTINGS" CC_HOME="$CCHOME" CC_DRY="$DRY" \
  python3 - <<'PY' || die "could not update $SETTINGS"
import json, os, shutil, sys, time

settings = os.environ["CC_SETTINGS"]
home = os.environ["CC_HOME"]
dry = os.environ["CC_DRY"] == "1"
notify = home + "/bin/notify.sh"
statusline = home + "/statusline/statusline.py"

try:
    with open(settings, encoding="utf-8") as f:
        data = json.load(f)
except ValueError as exc:
    sys.exit("%s is not valid JSON (%s); nothing was changed." % (settings, exc))
if not isinstance(data, dict):
    sys.exit("%s is not a JSON object; nothing was changed." % settings)
before = json.dumps(data, sort_keys=True)


def ours_hook(command):
    return "ccnotify/bin/notify.sh" in command or notify in command


def ours_statusline(command):
    return "ccnotify/statusline/statusline.py" in command or statusline in command


hooks = data.get("hooks")
if isinstance(hooks, dict):
    for event in list(hooks):
        groups = hooks[event]
        if not isinstance(groups, list):
            continue
        result = []
        for group in groups:
            if isinstance(group, dict) and isinstance(group.get("hooks"), list):
                kept = [h for h in group["hooks"]
                        if not (isinstance(h, dict) and ours_hook(str(h.get("command", ""))))]
                if len(kept) != len(group["hooks"]):
                    if not kept:
                        continue  # the group only held our hook
                    group = dict(group, hooks=kept)
            result.append(group)
        if result:
            hooks[event] = result
        else:
            del hooks[event]
    if not hooks:
        del data["hooks"]

line = data.get("statusLine")
if isinstance(line, dict) and ours_statusline(str(line.get("command", ""))):
    del data["statusLine"]

if json.dumps(data, sort_keys=True) == before:
    print("settings.json has nothing of ours: no changes")
elif dry:
    print("[dry-run] would remove CCNotify hooks (and statusLine if ours) from " + settings)
else:
    mode = os.stat(settings).st_mode & 0o777
    backup = "%s.ccnotify-backup-%s" % (settings, time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(settings, backup)
    tmp = "%s.%d.tmp" % (settings, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, settings)
    print("hooks removed from %s (backup: %s)" % (settings, backup))
PY
else
  say "no $SETTINGS: nothing to remove there"
fi

# --------------------------------------------------------------------------- LaunchAgent and running apps
if [ "$SKIP_LA" = 1 ]; then
  say "skipping the LaunchAgent (--skip-launchagent)"
else
  if [ -f "$LA_PLIST" ]; then
    step "unload and delete $LA_PLIST"
    if [ "$DRY" = 0 ]; then
      launchctl bootout "gui/$(id -u)/$LA_LABEL" >/dev/null 2>&1
      rm -f "$LA_PLIST"
    fi
  fi
  step "quit running CCNotify apps"
  if [ "$DRY" = 0 ]; then
    pkill -x ccnotify-sessions >/dev/null 2>&1
    pkill -x ccnotify-popup >/dev/null 2>&1
  fi
fi

# --------------------------------------------------------------------------- VS Code extension
editor_clis() {
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
  if [ -n "$CLIS" ]; then
    echo "$CLIS" | while IFS= read -r cli; do
      step "uninstall ccnotify.focus-terminal with $cli"
      if [ "$DRY" = 0 ]; then
        "$cli" --uninstall-extension ccnotify.focus-terminal >/dev/null 2>&1 || true
      fi
    done
  fi
fi

# --------------------------------------------------------------------------- files
if [ "$PURGE" = 1 ]; then
  if [ -d "$CCHOME" ]; then
    step "delete $CCHOME (including config.json and state/)"
    [ "$DRY" = 1 ] || rm -rf "$CCHOME"
  fi
else
  for item in "CCNotify.app" "CCNotify Sessions.app" bin statusline vscode-extension config.example.json LICENSE; do
    if [ -e "$CCHOME/$item" ]; then
      step "delete $CCHOME/$item"
      [ "$DRY" = 1 ] || rm -rf "${CCHOME:?}/$item"
    fi
  done
  say "kept $CCHOME/config.json and state/ (use --purge to delete them too)"
fi

say ""
if [ "$DRY" = 1 ]; then say "Dry run finished: nothing was changed."; else say "Done."; fi
