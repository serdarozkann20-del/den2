#!/usr/bin/env bash
# Compile-check every plugin script with the engine itself.
#
# gdparse / the LSP only check syntax. A call to a method that does not exist on a
# built-in type (`s.trim_left("_")`) is accepted by the parser and only rejected by
# Godot's analyzer - and then it shows up as `Nonexistent function '...' in base
# 'GDScript'` in every *caller*, which is a nasty thing to debug. `--check-only` runs
# the real analyzer and reports the offending file and line directly.
#
#   ./dev/check_scripts.sh                 # uses `godot` from PATH
#   GODOT=/opt/Godot_v4.7 --dev ./dev/check_scripts.sh
set -u
GODOT=${GODOT:-godot}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail=0

if ! command -v "${GODOT%% *}" >/dev/null 2>&1 && [ ! -x "${GODOT%% *}" ]; then
	echo "no godot binary ('$GODOT'); set GODOT=/path/to/godot" >&2
	exit 2
fi

for f in $(find "$ROOT/addons/rigbridge" -name '*.gd' | sort); do
	out=$("$GODOT" --headless --path "$ROOT" --check-only --script "res://${f#$ROOT/}" 2>&1)
	bad=$(printf '%s\n' "$out" | grep -E "SCRIPT ERROR|Parse Error|Cannot find member|Invalid .* on a base object" | head -20)
	if [ -n "$bad" ]; then
		echo "== ${f#$ROOT/}"
		printf '%s\n' "$bad"
		fail=1
	fi
done

if [ "$fail" -eq 0 ]; then
	echo "OK - every script compiles (analyzer clean)"
else
	echo "FAILED - see the first parse error above; it names the real file to fix"
fi
exit $fail
