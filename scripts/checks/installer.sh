#!/bin/sh
# Exercises install.sh and the built app's --install-hooks/--uninstall-hooks
# against a fake HOME. Never the real one -- the assertion below is the gate.
set -eu
cd "$(dirname "$0")/../.."

sh -n install.sh

app=dist/PeekAiBoo.app
bin="$app/Contents/MacOS/PeekAiBoo"
[ -x "$bin" ] || sh scripts/build-app.sh

real_home=$HOME
fake_home=$(mktemp -d "${TMPDIR:-/tmp/}pab-home.XXXXXX")
dir=$(mktemp -d "${TMPDIR:-/tmp/}pab.XXXXXX")
trap 'rm -rf "$fake_home" "$dir"' EXIT

export HOME="$fake_home"
export PEEKABOO_DIR="$dir"
[ "$HOME" != "$real_home" ] || { echo "refusing to run against the real HOME"; exit 1; }

mkdir -p "$HOME/.claude" "$HOME/.codex"
cp fixtures/settings-foreign-hooks.json "$HOME/.claude/settings.json"

"$bin" --install-hooks >/dev/null
after_first=$(cat "$HOME/.claude/settings.json")
"$bin" --install-hooks >/dev/null
after_second=$(cat "$HOME/.claude/settings.json")
[ "$after_first" = "$after_second" ] || { echo "install isn't idempotent"; exit 1; }

ls "$HOME"/.claude/settings.json.peek-ai-boo.*.bak >/dev/null 2>&1 || {
  echo "no backup written"; exit 1
}

[ -x "$dir/bin/peekaboo-hook" ] || { echo "hook binary missing or not executable"; exit 1; }

"$bin" --uninstall-hooks >/dev/null
python3 -c '
import json, sys
with open("fixtures/settings-foreign-hooks.json") as f:
    want = json.load(f)
with open(sys.argv[1]) as f:
    got = json.load(f)
sys.exit(0 if want == got else 1)
' "$HOME/.claude/settings.json" || { echo "uninstall did not restore foreign hooks"; exit 1; }
