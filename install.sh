#!/bin/sh
# Builds peek-ai-boo and installs it for the current user: the app goes to
# ~/Applications, the hook gets registered in Claude Code's (and Codex's,
# if present) config, then it's loaded as a login item and opened.
# --no-login-item means no login item, full stop: it also removes one left
# over from a previous plain install. The app still opens once, this run.
set -eu
cd "$(dirname "$0")"

login_item=1
for arg in "$@"; do
  [ "$arg" = "--no-login-item" ] && login_item=0
done

make -C hook
sh scripts/build-app.sh

dest="$HOME/Applications/PeekAiBoo.app"
mkdir -p "$HOME/Applications"
rm -rf "$dest"
cp -R dist/PeekAiBoo.app "$dest"

bin="$dest/Contents/MacOS/PeekAiBoo"
label="com.mohsensc.peekaiboo"
plist="$HOME/Library/LaunchAgents/$label.plist"

if [ "$login_item" = 1 ]; then
  "$bin" --install-hooks
  uid=$(id -u)
  # Bootout first so a reinstall is quiet: bootstrap on an already-loaded
  # label just errors. RunAtLoad then starts the app fresh, so no separate
  # `open` is needed on this path.
  old_pid=$(launchctl list 2>/dev/null | awk -v l="$label" '$3 == l { print $1 }')
  launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
  # bootout can return before the old process is actually gone. Wait it
  # out: if bootstrap starts the new copy while the old one still holds
  # events.sock, the new one finds it, exits 0 (main.swift's single-
  # instance check), and KeepAlive.SuccessfulExit=false means launchd
  # won't retry -- plist loaded, nothing running, until next login.
  if [ -n "${old_pid:-}" ] && [ "$old_pid" != "-" ]; then
    i=0
    while kill -0 "$old_pid" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  fi
  if ! launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null; then
    launchctl unload -w "$plist" >/dev/null 2>&1 || true
    launchctl load -w "$plist"
  fi
else
  "$bin" --install-hooks --no-login-item
  open "$dest"
fi
