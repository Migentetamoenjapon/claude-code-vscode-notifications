#!/bin/bash
# Builds CCNotify.app (popup) and "CCNotify Sessions.app" (menu bar) into <out-dir>.
#
# Usage: scripts/build.sh <out-dir> [--universal]
#   default      builds for this Mac's architecture
#   --universal  builds arm64 + x86_64 and joins them with lipo
#
# Needs the Xcode Command Line Tools (swiftc, codesign, lipo). The apps are signed ad hoc and do
# not depend on any other application.
set -euo pipefail

usage() { echo "Usage: $0 <out-dir> [--universal]" >&2; exit 2; }

OUT=""
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $arg" >&2; usage ;;
    *) [ -z "$OUT" ] || usage; OUT="$arg" ;;
  esac
done
[ -n "$OUT" ] || usage

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v swiftc >/dev/null 2>&1 || {
  echo "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
}

case "$(uname -m)" in
  arm64) HOST_ARCH=arm64 ;;
  *) HOST_ARCH=x86_64 ;;
esac
if [ "$UNIVERSAL" = 1 ]; then ARCHS="arm64 x86_64"; else ARCHS="$HOST_ARCH"; fi

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ccnotify-build.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# build_app <App name> <executable> <source dir> <bundle id> [<folder copied to Contents/Resources/emoji>]
build_app() {
  local name="$1" exe="$2" src="$3" bundle_id="$4" extra_resources="${5:-}"
  local app="$OUT/$name.app"
  local arch
  local slices=()
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

  for arch in $ARCHS; do
    swiftc -O -target "$arch-apple-macos12" -o "$TMP/$exe-$arch" "$ROOT/$src/main.swift"
    slices+=("$TMP/$exe-$arch")
  done
  if [ "${#slices[@]}" -gt 1 ]; then
    lipo -create "${slices[@]}" -output "$app/Contents/MacOS/$exe"
  else
    cp "${slices[0]}" "$app/Contents/MacOS/$exe"
  fi
  chmod 755 "$app/Contents/MacOS/$exe"

  # Extra resources of this app (the menu bar app's per-session emoji), copied before signing
  if [ -n "$extra_resources" ]; then
    mkdir -p "$app/Contents/Resources/emoji"
    cp -R "$ROOT/$extra_resources/." "$app/Contents/Resources/emoji/"
  fi

  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$exe</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
  codesign --force --deep -s - "$app" >/dev/null 2>&1
  echo "built: $app"
}

build_app "CCNotify" "ccnotify-popup" "src/popup" "io.github.ccnotify.popup"
build_app "CCNotify Sessions" "ccnotify-sessions" "src/menubar" "io.github.ccnotify.sessions" "assets/emoji"
