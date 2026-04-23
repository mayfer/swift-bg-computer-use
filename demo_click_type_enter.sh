#!/usr/bin/env bash
set -euo pipefail

BIN="${BIN:-./.build/release/macos-bg-cua}"
APP="${APP:-Helium}"
QUERY="${QUERY:-testing}"
URL_X="${URL_X:-235}"
URL_Y="${URL_Y:-49}"
SHOT_BEFORE="${SHOT_BEFORE:-/tmp/helium-before-click-type-enter.png}"
SHOT_TYPED="${SHOT_TYPED:-/tmp/helium-after-type.png}"
SHOT_ENTER="${SHOT_ENTER:-/tmp/helium-after-enter.png}"

if [[ ! -x "$BIN" ]]; then
  echo "missing $BIN; run: swift build -c release" >&2
  exit 1
fi

windows_json="[]"
wid="${WID:-}"
if [[ -z "$wid" ]]; then
  for _ in {1..10}; do
    windows_json="$("$BIN" list-windows --app "$APP")"
    if [[ "$windows_json" == "[]" ]]; then
      windows_json="$("$BIN" list-windows)"
    fi
    wid="$(printf '%s\n' "$windows_json" | /usr/bin/python3 -c '
import json, sys
windows = json.load(sys.stdin)
windows = [
    w for w in windows
    if w.get("width", 0) > 200
    and w.get("height", 0) > 100
    and (w.get("owner") == "Helium" or w.get("bundleID") == "net.imput.helium")
]
if windows:
    print(windows[0]["wid"])
')"
    if [[ -n "$wid" ]]; then
      break
    fi
    sleep 0.2
  done
  if [[ -z "$wid" ]]; then
    echo "no usable $APP window found" >&2
    echo "$windows_json" >&2
    exit 1
  fi
fi

echo "app=$APP wid=$wid url_coord=${URL_X},${URL_Y} query=$QUERY"

echo "+ screenshot before"
"$BIN" background screenshot "$wid" -o "$SHOT_BEFORE" --png

echo "+ background click URL bar"
"$BIN" background click "$wid" "$URL_X" "$URL_Y"

echo "+ background type query with --replace"
type_result="$("$BIN" background type "$wid" "$QUERY" --replace)"
echo "$type_result"

echo "+ screenshot after type"
"$BIN" background screenshot "$wid" -o "$SHOT_TYPED" --png

echo "+ background press Enter"
enter_result="$("$BIN" background press "$wid" Enter)"
echo "$enter_result"

sleep 2

echo "+ screenshot after Enter"
"$BIN" background screenshot "$wid" -o "$SHOT_ENTER" --png

echo "screenshots:"
echo "  before: $SHOT_BEFORE"
echo "  typed:  $SHOT_TYPED"
echo "  enter:  $SHOT_ENTER"
