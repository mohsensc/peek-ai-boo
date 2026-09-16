#!/bin/sh
# Builds the bundle, checks it, and launches it against a throwaway dir.
set -u
sh scripts/build-app.sh || exit 1
app=dist/PeekAiBoo.app
bin=$app/Contents/MacOS/PeekAiBoo
plutil -lint "$app/Contents/Info.plist" || exit 1
codesign --verify --strict "$app" || exit 1
dir=$(mktemp -d "${TMPDIR:-/tmp/}pab.XXXXXX")
PEEKABOO_DIR=$dir "$bin" & pid=$!
trap 'kill $pid 2>/dev/null; rm -rf "$dir"' EXIT
i=0; while [ ! -S "$dir/events.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
[ -S "$dir/events.sock" ] || { echo "events.sock never showed up"; exit 1; }
[ "$(stat -f %Lp "$dir")" = 700 ] || { echo "dir isn't 0700"; exit 1; }
[ "$(stat -f %Lp "$dir/events.sock")" = 600 ] || { echo "socket isn't 0600"; exit 1; }
PEEKABOO_DIR=$dir "$bin" & second=$!
i=0; while kill -0 $second 2>/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
if kill -0 $second 2>/dev/null; then kill $second; echo "second copy didn't quit"; exit 1; fi
wait $second || { echo "second copy exited non-zero"; exit 1; }
PEEKABOO_DIR=$dir python3 scripts/fake-hook.py send fixtures/claude-basic.jsonl || exit 1
sleep 0.3
kill -0 $pid || { echo "app died on the fixture"; exit 1; }
