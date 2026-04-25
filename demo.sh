#!/usr/bin/env bash
set -euo pipefail

BIN="${BIN:-./.build/release/macos-bg-cua}"
APP="${APP:-Helium}"

"$BIN" cursor start background "$APP" 50 50 --duration 0.0 --any-window
"$BIN" cursor move 733 531 --duration 1.55 --wait
"$BIN" cursor click --wait
"$BIN" background click "$APP" 733 531 --any-window
sleep 2.2 && "$BIN" cursor stop
