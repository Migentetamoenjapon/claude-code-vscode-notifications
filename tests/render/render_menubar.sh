#!/bin/bash
# Renders the menu bar item and its open menu to docs/img/menubar-*.png with the menu bar app's test hook
# (CCNOTIFY_CAPTURE_MENU, CCNOTIFY_THEME). The open menu is a real grab of the app's own menu window; the
# status item is drawn by the app from its button's real symbol, tint and count (a window grab of it comes
# out untinted). Both sit on the same soft backdrop the popup pictures use. The menu is grabbed at the
# screen's own pixel density, so run it on a Retina Mac for sharp text. Needs a logged-in macOS GUI
# session with the display awake and unlocked (otherwise the menu has no pixels and the capture fails
# with a message; `caffeinate -u -t 60 &` wakes the display), but no Screen Recording permission. Each
# run flashes the menu for about a second. All sessions below are fictional.
#
# Files written (light and dark of each):
#   menubar-<theme>.png       English, color style (the default; neutral looks the same in the menu bar)
#   menubar-es-<theme>.png    Spanish, color style
#   menubar-mono-<theme>.png  English, popup.style = mono
#
# Usage: tests/render/render_menubar.sh [out-dir]     (default: docs/img)
# CCNOTIFY_MENUBAR_BIN=<path to ccnotify-sessions> skips the build and uses that binary instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/docs/img}"
mkdir -p "$OUT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ccnotify-render.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ -n "${CCNOTIFY_MENUBAR_BIN:-}" ]; then
  BIN="$CCNOTIFY_MENUBAR_BIN"
else
  "$ROOT/scripts/build.sh" "$WORK/build" >/dev/null
  BIN="$WORK/build/CCNotify Sessions.app/Contents/MacOS/ccnotify-sessions"
fi
export CCNOTIFY_HOME="$WORK/home"     # keeps the render away from any real install
mkdir -p "$CCNOTIFY_HOME"

# write_session <id> <project> <state> <seconds ago> <seen true|false> <tasks> <summary> <request>
# The pid is this script's own, so the menu bar app finds the session's process alive and keeps it.
write_session() {
  local id="$1" project="$2" state="$3" ago="$4" seen="$5" tasks="$6" summary="$7" request="$8"
  local now since
  now="$(date +%s)"
  since=$((now - ago))
  printf '{"session": "%s", "project": "%s", "state": "%s", "since": %s, "updated_at": %s, "pid": %s, "seen": %s, "tasks": %s, "summary": "%s", "request": "%s", "transcript": ""}\n' \
    "$id" "$project" "$state" "$since" "$now" "$$" "$seen" "$tasks" "$summary" "$request" \
    > "$CCNOTIFY_HOME/state/sessions/$id.json"
}

# write_sessions <en|es>: five sessions that fill every group of the menu
write_sessions() {
  rm -rf "$CCNOTIFY_HOME/state"
  mkdir -p "$CCNOTIFY_HOME/state/sessions"
  if [ "$1" = es ]; then
    write_session s1 web-shop needs 90 false 0 "Pide permiso para usar Bash: npm run build" ""
    write_session s2 api-server wrote 240 false 0 "Agregó la lógica de reintentos y pasan las 42 pruebas." ""
    write_session s3 docs-site thinking 120 false 0 "" "reescribe la guía de instalación"
    write_session s4 data-pipeline thinking 420 false 2 "Dos agentes están comparando los analizadores." ""
    write_session s5 mobile-app wrote 3900 true 0 "Lista para revisar las pantallas de bienvenida." ""
  else
    write_session s1 web-shop needs 90 false 0 "Asks permission to use Bash: npm run build" ""
    write_session s2 api-server wrote 240 false 0 "Added the retry logic and all 42 tests pass." ""
    write_session s3 docs-site thinking 120 false 0 "" "rewrite the install guide"
    write_session s4 data-pipeline thinking 420 false 2 "Two agents are comparing the parsers." ""
    write_session s5 mobile-app wrote 3900 true 0 "Ready to review the onboarding screens." ""
  fi
}

# render <file name> <theme> <language en|es> <popup style>
render() {
  local name="$1" theme="$2" lang="$3" style="$4"
  printf '{"language": "%s", "popup": {"style": "%s"}}\n' "$lang" "$style" > "$CCNOTIFY_HOME/config.json"
  write_sessions "$lang"
  rm -f "$OUT/$name"
  # The app quits by itself once the picture is saved (and after a timeout if it never gets there)
  CCNOTIFY_CAPTURE_MENU="$OUT/$name" CCNOTIFY_THEME="$theme" "$BIN"
  [ -s "$OUT/$name" ] || { echo "no picture written: $name" >&2; exit 1; }
  echo "rendered: $name"
}

for theme in light dark; do
  render "menubar-$theme.png" "$theme" en color
  render "menubar-es-$theme.png" "$theme" es color
  render "menubar-mono-$theme.png" "$theme" en mono
done

echo "Done. Images in: $OUT"
