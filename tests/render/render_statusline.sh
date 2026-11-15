#!/bin/bash
# Renders the status line to docs/img/statusline[-es]-<theme>.png. The text in the images is the
# real stdout of statusline/statusline.py, fed with fictional input inside a throwaway home
# directory, then drawn as a terminal panel by tests/render/ansi_to_png.swift. Needs macOS (AppKit)
# and python3. Nothing from a real install is read or written, and the ticker is off, so the
# script makes no network request.
#
# Usage: tests/render/render_statusline.sh [out-dir]     (default: docs/img)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/docs/img}"
mkdir -p "$OUT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ccnotify-statusline.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "compiling ansi_to_png (this can take a while)..."
swiftc -O "$ROOT/tests/render/ansi_to_png.swift" -o "$WORK/ansi_to_png"

# make_home <lang>: builds $WORK/home-<lang>/ (config + state) and $WORK/input-<lang>.json.
make_home() {
  python3 - "$WORK" "$1" <<'PY'
import json, os, sys, time

work, lang = sys.argv[1], sys.argv[2]
home = os.path.join(work, "home-" + lang)
state = os.path.join(home, "state", "statusline")
os.makedirs(state, exist_ok=True)

# Config: plan price makes the dollar figures appear; no ticker (so no network access at all);
# the language is set explicitly so the script never asks macOS for it.
with open(os.path.join(home, "config.json"), "w") as f:
    json.dump({"language": lang, "statusline": {"plan_monthly_usd": 100, "ticker": ""}}, f)

# Transcript with 45,000 new tokens (input + cache writes + output) in one assistant message.
transcript = os.path.join(home, "transcript.jsonl")
with open(transcript, "w") as f:
    f.write(json.dumps({"type": "assistant", "timestamp": "2099-01-01T00:00:00Z", "message": {
        "id": "msg-1", "usage": {"input_tokens": 3000, "cache_creation_input_tokens": 30000,
                                 "output_tokens": 12000}}}, separators=(",", ":")) + "\n")

now = time.time()
week_reset = now + 3 * 86400
lt = time.localtime(now)
five_reset = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 15, 0, 0, 0, 0, -1))   # 3:00pm local

# The session's share of the week is split across the week's sessions by cost: a second, earlier
# session on the same week makes this one (cost 1.50) come out at 45% * 1.50 / 56.25 = 1.2%.
with open(os.path.join(state, "earlier-session.week"), "w") as f:
    json.dump({"reset": week_reset, "base": 0, "cost": 54.75}, f)

data = {
    "session_id": "demo-session",
    "transcript_path": transcript,
    "workspace": {"project_dir": "/work/my-project"},
    "model": {"display_name": "Sonnet"},
    "effort": {"level": "high"},
    "context_window": {"used_percentage": 52},
    "cost": {"total_cost_usd": 1.5},
    "rate_limits": {"five_hour": {"used_percentage": 12, "resets_at": five_reset},
                    "seven_day": {"used_percentage": 45, "resets_at": week_reset}},
}
with open(os.path.join(work, "input-" + lang + ".json"), "w") as f:
    json.dump(data, f)
PY
}

# render_set <lang> <file-prefix>: runs the script once and writes the light and dark images.
render_set() {
  local lang="$1" prefix="$2" theme
  make_home "$lang"
  # COLUMNS is unset so the script does not trim the line; HOME and CLAUDE_CONFIG_DIR point at
  # the temp dir in case anything falls back to them.
  env -u COLUMNS HOME="$WORK/home-$lang/user" CLAUDE_CONFIG_DIR="$WORK/home-$lang/claude" \
    CCNOTIFY_HOME="$WORK/home-$lang" LC_ALL=C \
    python3 "$ROOT/statusline/statusline.py" < "$WORK/input-$lang.json" > "$WORK/line-$lang.txt"
  # What the images say, without escape codes:
  python3 -c 'import re,sys; print(re.sub(r"\033\[[0-9;]*m", "", sys.stdin.read()), end="")' \
    < "$WORK/line-$lang.txt"
  for theme in light dark; do
    "$WORK/ansi_to_png" --out "$OUT/$prefix-$theme.png" --theme "$theme" --width 760 --scale 2 \
      < "$WORK/line-$lang.txt"
    echo "rendered: $prefix-$theme.png"
  done
}

render_set en statusline
render_set es statusline-es

echo "Done. Images in: $OUT"
