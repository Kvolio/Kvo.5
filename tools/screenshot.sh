#!/usr/bin/env bash
# Render the game to a PNG. Needs a display; uses Xvfb when there is none.
#
#   tools/screenshot.sh out.png                       whole battlefield
#   tools/screenshot.sh out.png --screenshot-zoom=1.1 --screenshot-focus=1
#
# Useful for eyeballing a change without a desktop, and for catching the class of
# bug that only shows up once something is actually drawn.
set -euo pipefail

GODOT="${GODOT:-godot}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:?usage: screenshot.sh <output.png> [extra args]}"
shift || true

RUNNER=()
if [[ -z "${DISPLAY:-}" ]] && command -v xvfb-run >/dev/null; then
  RUNNER=(xvfb-run -a)
fi

"${RUNNER[@]}" "$GODOT" --path "$PROJECT_DIR" --rendering-driver opengl3 \
  --resolution 1600x900 -- --screenshot="$OUT" --screenshot-frame=240 "$@"
