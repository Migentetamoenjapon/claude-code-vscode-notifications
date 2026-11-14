#!/bin/bash
# Renders sample popups to docs/img/popup-<name>-<theme>.png using the popup's test hooks
# (CCNOTIFY_CAPTURE, CCNOTIFY_THEME, CCNOTIFY_COMPACT). Needs a logged-in macOS GUI session, but no
# Screen Recording permission. All projects and texts below are fictional.
#
# Usage: tests/render/render_samples.sh [out-dir]     (default: docs/img)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/docs/img}"
mkdir -p "$OUT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ccnotify-render.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

"$ROOT/scripts/build.sh" "$WORK/build" >/dev/null
BIN="$WORK/build/CCNotify.app/Contents/MacOS/ccnotify-popup"
export CCNOTIFY_HOME="$WORK/home"     # keeps the render away from any real install
mkdir -p "$CCNOTIFY_HOME"

# render <name> <theme> [compact]  -- reads the sample JSON from $WORK/<name>.json
render() {
  local name="$1" theme="$2" compact="${3:-0}"
  local json="$WORK/$name-$theme.json"
  cp "$WORK/$name.json" "$json"
  CCNOTIFY_CAPTURE="$OUT/popup-$name-$theme.png" CCNOTIFY_THEME="$theme" CCNOTIFY_COMPACT="$compact" \
    "$BIN" "$json"
  echo "rendered: popup-$name-$theme.png"
}

# --- Samples ------------------------------------------------------------------------------------

cat > "$WORK/done.json" <<'JSON'
{"title": "my-app", "kind": "done", "language": "en",
 "text": "Fixed the failing login test. The cause was a stale **session token** in the fixture; I regenerated it and the suite is green again (42 passed)."}
JSON

cat > "$WORK/table.json" <<'JSON'
{"title": "payments-api", "kind": "done", "language": "en",
 "text": "## Benchmark results\n\nI ran the new `batch_charge()` path against the old one on 10,000 sample orders.\n\n| Path | Requests | p95 latency | Errors |\n|---|---|---|---|\n| old `charge()` | 10,000 | 412 ms | 0.8 % |\n| new `batch_charge()` | 10,000 | 96 ms | 0.0 % |\n\n### What changed\n\n- Orders are grouped by merchant before the call\n- Retries use **exponential backoff** (max 3)\n- Errors now carry the order id\n\nNext step: roll it out behind the `BATCH_CHARGE` flag, then remove the old path."}
JSON

cat > "$WORK/permission.json" <<'JSON'
{"title": "website", "kind": "permission", "language": "en",
 "text": "Claude needs your permission to use **Bash**:\n\n```\nnpm run build && rsync -av dist/ staging:/var/www/site/\n```"}
JSON

cat > "$WORK/question.json" <<'JSON'
{"title": "my-app", "kind": "question", "language": "en",
 "text": "Which database should the new service use?\n\n1. **PostgreSQL**: matches the rest of the stack\n2. **SQLite**: simpler, but single-writer\n3. Something else (tell me)"}
JSON

cat > "$WORK/agent.json" <<'JSON'
{"title": "payments-api", "kind": "agent", "language": "en",
 "text": "The **reviewer** agent needs your input: two migrations touch the `invoices` table. Should it keep the newer one and drop `0042_add_vat.sql`?"}
JSON

{
  printf '{"title": "website", "kind": "done", "language": "en", "text": "'
  printf '## Migration report\\n\\nI went through every page of the old site and mapped it to the new layout. Details below.\\n\\n'
  i=1
  while [ "$i" -le 14 ]; do
    printf '### Section %d\\n\\n- Moved `pages/section-%d.html` to `content/section-%d.md`\\n- Converted the **navigation** links and checked them one by one\\n- Left a redirect in `redirects.txt` for the old URL\\n\\n' "$i" "$i" "$i"
    i=$((i + 1))
  done
  printf 'All sections are migrated. Please review the redirects before we deploy."}\n'
} > "$WORK/long.json"

cat > "$WORK/compact.json" <<'JSON'
{"title": "my-app", "kind": "done", "language": "en",
 "text": "Refactored the settings screen into three components. I also moved the validation helpers into `utils/validate.ts`, added tests for the empty-form case, and updated the README with the new folder layout. Nothing else was touched."}
JSON

cat > "$WORK/table-es.json" <<'JSON'
{"title": "payments-api", "kind": "done", "language": "es",
 "text": "## Resultados de la prueba\n\nComparé la ruta nueva `batch_charge()` con la anterior en 10.000 pedidos de ejemplo.\n\n| Ruta | Solicitudes | Latencia p95 | Errores |\n|---|---|---|---|\n| `charge()` anterior | 10.000 | 412 ms | 0,8 % |\n| `batch_charge()` nueva | 10.000 | 96 ms | 0,0 % |\n\n### Qué cambió\n\n- Los pedidos se agrupan por comercio antes de la llamada\n- Los reintentos usan **espera exponencial** (máximo 3)\n- Los errores ahora incluyen el id del pedido\n\nSiguiente paso: activarla detrás del flag `BATCH_CHARGE` y luego quitar la ruta anterior."}
JSON

cat > "$WORK/permission-es.json" <<'JSON'
{"title": "website", "kind": "permission", "language": "es",
 "text": "Claude necesita tu permiso para usar **Bash**:\n\n```\nnpm run build && rsync -av dist/ staging:/var/www/site/\n```"}
JSON

for theme in light dark; do
  for name in done table permission question agent long table-es permission-es; do
    render "$name" "$theme"
  done
  render compact "$theme" 1
done

echo "Done. Images in: $OUT"
