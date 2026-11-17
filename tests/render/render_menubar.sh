#!/bin/bash
# Renders the menu bar item and its open panel to docs/img/menubar-*.png with the menu bar app's test hooks
# (CCNOTIFY_CAPTURE_MENU, CCNOTIFY_THEME, CCNOTIFY_CAPTURE_OPEN, CCNOTIFY_CAPTURE_BUBBLE, CCNOTIFY_CAPTURE_PICKER,
# CCNOTIFY_CAPTURE_OPTIONS). The emoji come from the built app's bundle (assets/emoji). The panel is a real grab
# of the app's own popover window; the status item is drawn by the app at its real place over a piece of menu bar
# (a window grab of it comes out without what the system paints on screen), so the panel's arrow visibly points at the
# icon. Both sit on the same soft backdrop the popup pictures use. The panel is grabbed at the screen's own pixel
# density, so run it on a Retina Mac for sharp text. Needs a logged-in macOS GUI session with the display awake and
# unlocked (otherwise the panel has no pixels and the capture fails with a message; `caffeinate -u -t 60 &` wakes the
# display), but no Screen Recording permission. Each run flashes the panel for about three seconds. All sessions
# below are fictional.
#
# Files written (light and dark of each):
#   menubar-<theme>.png          English, color style (the default; neutral looks the same in the menu bar)
#   menubar-bubble-<theme>.png   one row open, as when the mouse rests on it, and the bubble with the whole message
#   menubar-remind-<theme>.png   that row with its "Remind me in" choices
#   menubar-picker-<theme>.png   that row with its emoji picker
#   menubar-options-<theme>.png  the options page
#   menubar-es-<theme>.png       Spanish, color style, one row open
#   menubar-mono-<theme>.png     English, popup.style = mono (the emoji turn gray too), one row open
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
unset CCNOTIFY_EMOJI_DIR
export CCNOTIFY_HOME="$WORK/home"     # keeps the render away from any real install
mkdir -p "$CCNOTIFY_HOME"
STATE="$CCNOTIFY_HOME/state"
NOW="$(date +%s)"

# write_session <id> <project> <state> <seconds ago> <seen true|false> <tasks> <summary> <request> <kind> <transcript>
# The pid is this script's own, so the menu bar app finds the session's process alive and keeps it.
write_session() {
  local id="$1" project="$2" state="$3" ago="$4" seen="$5" tasks="$6" summary="$7" request="$8" kind="$9" transcript="${10}"
  local since=$((NOW - ago)) extra=""
  [ -n "$kind" ] && extra=", \"kind\": \"$kind\""
  printf '{"session": "%s", "project": "%s", "state": "%s", "since": %s, "updated_at": %s, "pid": %s, "seen": %s, "tasks": %s, "summary": "%s", "request": "%s", "transcript": "%s"%s}\n' \
    "$id" "$project" "$state" "$since" "$NOW" "$$" "$seen" "$tasks" "$summary" "$request" "$transcript" "$extra" \
    > "$STATE/sessions/$id.json"
}

# write_context <id> <percent>: what the status line leaves in state/context/<id>.json
write_context() {
  printf '{"pct": %s, "at": %s}\n' "$2" "$NOW" > "$STATE/context/$1.json"
}

# write_sessions <en|es>: seven sessions that fill every kind of row, plus the optional files the status line writes
write_sessions() {
  rm -rf "$STATE"
  mkdir -p "$STATE/sessions" "$STATE/context" "$STATE/menubar/pins" "$STATE/menubar/reminders" "$WORK/transcripts"
  chmod 700 "$STATE/menubar"
  # The last message of api-server, for the bubble
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"I added the retry logic to the API client and all 42 tests pass.\n\n**What changed**\n\n- Failed requests are retried up to 3 times with exponential backoff\n- Timeouts now carry the request id\n- `RetryPolicy` is configurable per client\n\nNext step: roll it out behind the `RETRIES` flag, then remove the old path."}]}}' \
    > "$WORK/transcripts/s3.jsonl"
  if [ "$1" = es ]; then
    write_session s1 web-shop needs 90 false 0 "Pide permiso para usar Bash: npm run build" "" permission ""
    write_session s2 design-docs needs 300 false 0 "¿Qué base de datos debe usar el servicio nuevo?" "" question ""
    write_session s3 api-server wrote 240 false 0 "Agregó la lógica de reintentos y pasan las 42 pruebas." "" "" "$WORK/transcripts/s3.jsonl"
    write_session s4 etl thinking 420 false 2 "Dos agentes están comparando los analizadores." "" "" ""
    write_session s5 docs-site thinking 120 false 0 "" "reescribe la guía de instalación" "" ""
    write_session s6 mobile-app wrote 3900 true 0 "Lista para revisar las pantallas de bienvenida." "" "" ""
    write_session s7 billing wrote 600 false 0 "Terminó la migración de facturas." "" "" ""
  else
    write_session s1 web-shop needs 90 false 0 "Asks permission to use Bash: npm run build" "" permission ""
    write_session s2 design-docs needs 300 false 0 "Which database should the new service use?" "" question ""
    write_session s3 api-server wrote 240 false 0 "Added the retry logic and all 42 tests pass." "" "" "$WORK/transcripts/s3.jsonl"
    write_session s4 etl thinking 420 false 2 "Two agents are comparing the parsers." "" "" ""
    write_session s5 docs-site thinking 120 false 0 "" "rewrite the install guide" "" ""
    write_session s6 mobile-app wrote 3900 true 0 "Ready to review the onboarding screens." "" "" ""
    write_session s7 billing wrote 600 false 0 "Finished the invoice migration." "" "" ""
  fi
  write_context s1 84
  write_context s2 41
  write_context s3 63
  write_context s4 22
  write_context s6 93
  : > "$STATE/menubar/pins/s6"                                                   # mobile-app is pinned
  printf '{"at": %s, "since": %s}\n' "$((NOW + 240))" "$((NOW - 600))" > "$STATE/menubar/reminders/s7.json"   # billing: reminder in 4 min
  printf '{"five_hour": {"pct": 37, "resets_at": %s}, "seven_day": {"pct": 82, "resets_at": %s}, "at": %s}\n' \
    "$((NOW + 9500))" "$((NOW + 3 * 86400))" "$NOW" > "$STATE/usage.json"
}

# render <file name> <theme> <language en|es> <popup style> [extra VAR=value ...]
render() {
  local name="$1" theme="$2" lang="$3" style="$4"
  shift 4
  printf '{"language": "%s", "popup": {"style": "%s"}}\n' "$lang" "$style" > "$CCNOTIFY_HOME/config.json"
  write_sessions "$lang"
  # RENDER_ONLY="s2 s3": keep only those sessions; RENDER_NO_USAGE=1: no "Limits" block (a shorter panel, for the picker)
  if [ -n "${RENDER_ONLY:-}" ]; then
    for f in "$STATE"/sessions/*.json; do
      case " $RENDER_ONLY " in *" $(basename "$f" .json) "*) ;; *) rm -f "$f" ;; esac
    done
  fi
  [ "${RENDER_NO_USAGE:-}" = 1 ] && rm -f "$STATE/usage.json"
  rm -f "$OUT/$name"
  # The app quits by itself once the picture is saved (and after a timeout if it never gets there)
  env CCNOTIFY_CAPTURE_MENU="$OUT/$name" CCNOTIFY_THEME="$theme" "$@" "$BIN"
  [ -s "$OUT/$name" ] || { echo "no picture written: $name" >&2; exit 1; }
  echo "rendered: $name"
}

for theme in light dark; do
  render "menubar-$theme.png" "$theme" en color
  render "menubar-bubble-$theme.png" "$theme" en color CCNOTIFY_CAPTURE_OPEN=s3 CCNOTIFY_CAPTURE_BUBBLE=s3
  render "menubar-remind-$theme.png" "$theme" en color CCNOTIFY_CAPTURE_REMIND=s3
  RENDER_ONLY="s2 s3" RENDER_NO_USAGE=1 render "menubar-picker-$theme.png" "$theme" en color CCNOTIFY_CAPTURE_PICKER=s3
  render "menubar-options-$theme.png" "$theme" en color CCNOTIFY_CAPTURE_OPTIONS=1
  render "menubar-es-$theme.png" "$theme" es color CCNOTIFY_CAPTURE_OPEN=s3
  render "menubar-mono-$theme.png" "$theme" en mono CCNOTIFY_CAPTURE_OPEN=s3
done

echo "Done. Images in: $OUT"
