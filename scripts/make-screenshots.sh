#!/bin/sh
# Redraws the pictures in README.md.
#
# The app draws its own panel offscreen — no window is shown, no screen
# recording permission is asked for, and the three accounts in it are invented,
# so no real email or quota is published. Run it after any change to the panel
# and the README can never show a version of the app that no longer exists.
#
#   scripts/make-screenshots.sh [--help]
set -e

case "$1" in
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) echo "make-screenshots: unknown argument '$1'" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/Package.swift" ] || { echo "make-screenshots: $ROOT is not the repo root" >&2; exit 1; }

"$ROOT/scripts/make-app.sh" >/dev/null
APP="$ROOT/ClaudeAccountSwitcher.app/Contents/MacOS/ClaudeAccountSwitcher"
[ -x "$APP" ] || { echo "make-screenshots: $APP was not built" >&2; exit 1; }

"$APP" --screenshot "$ROOT/docs/panel.png"
"$APP" --screenshot "$ROOT/docs/panel-dark.png" --dark
