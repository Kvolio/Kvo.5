#!/usr/bin/env bash
# Run the headless test suite.
#
#   tools/test.sh                       all suites
#   tools/test.sh --filter=rng          only suites whose filename contains "rng"
#   tools/test.sh --exclude=gun_action  everything except the integration suite
#
# The integration suite runs whole battles and takes a couple of minutes on its own,
# so splitting the run with --exclude is useful when iterating on the unit suites.
#
# The import pass is not optional. Godot resolves `class_name` types from a cache
# built during import; running --script against a stale cache makes every suite that
# references a newly added class fail to parse, which looks like a code error and
# is not one.
set -euo pipefail

GODOT="${GODOT:-godot}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$GODOT" --headless --path "$PROJECT_DIR" --import >/dev/null 2>&1 || true
exec "$GODOT" --headless --path "$PROJECT_DIR" --script res://tests/run_tests.gd -- "$@"
