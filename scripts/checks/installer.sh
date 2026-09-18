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
label="com.mohsensc.peekaiboo"
fake_home=$(mktemp -d "${TMPDIR:-/tmp/}pab-home.XXXXXX")
dir=$(mktemp -d "${TMPDIR:-/tmp/}pab.XXXXXX")
trap 'rm -rf "$fake_home" "$dir"' EXIT

export HOME="$fake_home"
export PEEKABOO_DIR="$dir"
# PEEKABOO_SKIP_LAUNCHCTL: gui/$UID is the real login session no matter what
# $HOME points at, so uninstall's launchctl bootout must not fire here.
export PEEKABOO_SKIP_LAUNCHCTL=1
[ "$HOME" != "$real_home" ] || { echo "refusing to run against the real HOME"; exit 1; }

mkdir -p "$HOME/.claude" "$HOME/.codex"
cp fixtures/settings-foreign-hooks.json "$HOME/.claude/settings.json"

# Checksum every real location this run must never touch, so a regression
# here fails loudly instead of silently reaching the real machine.
real_checksum() {
  { [ -e "$1" ] && find "$1" -type f -exec shasum {} \; | sort; } 2>/dev/null | shasum
}
real_agents_before=$(real_checksum "$real_home/Library/LaunchAgents")
real_settings_before=$(real_checksum "$real_home/.claude/settings.json")
real_codex_before=$(real_checksum "$real_home/.codex")
real_apps_before=$(real_checksum "$real_home/Applications")

plist="$HOME/Library/LaunchAgents/$label.plist"

"$bin" --install-hooks >/dev/null
after_first=$(cat "$HOME/.claude/settings.json")
"$bin" --install-hooks >/dev/null
after_second=$(cat "$HOME/.claude/settings.json")
[ "$after_first" = "$after_second" ] || { echo "install isn't idempotent"; exit 1; }

ls "$HOME"/.claude/settings.json.peek-ai-boo.*.bak >/dev/null 2>&1 || {
  echo "no backup written"; exit 1
}

[ -x "$dir/bin/peekaboo-hook" ] || { echo "hook binary missing or not executable"; exit 1; }

[ -f "$plist" ] || { echo "login item plist wasn't written"; exit 1; }
plutil -lint "$plist" >/dev/null || { echo "login item plist is malformed"; exit 1; }
got_label=$(plutil -extract Label raw -o - "$plist")
[ "$got_label" = "$label" ] || { echo "wrong plist label: $got_label"; exit 1; }
got_program=$(plutil -extract ProgramArguments.0 raw -o - "$plist")
case "$got_program" in
  */PeekAiBoo.app/Contents/MacOS/PeekAiBoo) ;;
  *) echo "wrong plist program path: $got_program"; exit 1 ;;
esac
[ -x "$got_program" ] || { echo "plist points at a program that doesn't exist: $got_program"; exit 1; }
got_keepalive=$(plutil -extract KeepAlive.SuccessfulExit raw -o - "$plist")
[ "$got_keepalive" = "false" ] || { echo "KeepAlive.SuccessfulExit should be false: $got_keepalive"; exit 1; }

plist_after_first=$(cat "$plist")
"$bin" --install-hooks >/dev/null
plist_after_second=$(cat "$plist")
[ "$plist_after_first" = "$plist_after_second" ] || { echo "login item install isn't idempotent"; exit 1; }

"$bin" --uninstall-hooks >/dev/null
python3 -c '
import json, sys
with open("fixtures/settings-foreign-hooks.json") as f:
    want = json.load(f)
with open(sys.argv[1]) as f:
    got = json.load(f)
sys.exit(0 if want == got else 1)
' "$HOME/.claude/settings.json" || { echo "uninstall did not restore foreign hooks"; exit 1; }

[ ! -f "$plist" ] || { echo "login item plist survived uninstall"; exit 1; }

# --no-login-item: hooks still install, and it takes back a login item a
# previous plain install left behind, not just skip writing a new one.
cp fixtures/settings-foreign-hooks.json "$HOME/.claude/settings.json"
"$bin" --install-hooks >/dev/null
[ -f "$plist" ] || { echo "setup for --no-login-item check is missing the plist"; exit 1; }
"$bin" --install-hooks --no-login-item >/dev/null
[ ! -f "$plist" ] || { echo "--no-login-item left an existing plist in place"; exit 1; }
"$bin" --uninstall-hooks >/dev/null

real_agents_after=$(real_checksum "$real_home/Library/LaunchAgents")
real_settings_after=$(real_checksum "$real_home/.claude/settings.json")
real_codex_after=$(real_checksum "$real_home/.codex")
real_apps_after=$(real_checksum "$real_home/Applications")

[ "$real_agents_before" = "$real_agents_after" ] || { echo "real ~/Library/LaunchAgents changed"; exit 1; }
[ "$real_settings_before" = "$real_settings_after" ] || { echo "real ~/.claude/settings.json changed"; exit 1; }
[ "$real_codex_before" = "$real_codex_after" ] || { echo "real ~/.codex changed"; exit 1; }
[ "$real_apps_before" = "$real_apps_after" ] || { echo "real ~/Applications changed"; exit 1; }
