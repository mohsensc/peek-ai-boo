#!/bin/sh
# Builds peek-ai-boo and installs it for the current user: the app goes to
# ~/Applications, the hook gets registered in Claude Code's (and Codex's,
# if present) config, then the app opens.
set -eu
cd "$(dirname "$0")"

make -C hook
sh scripts/build-app.sh

dest="$HOME/Applications/PeekAiBoo.app"
mkdir -p "$HOME/Applications"
rm -rf "$dest"
cp -R dist/PeekAiBoo.app "$dest"

"$dest/Contents/MacOS/PeekAiBoo" --install-hooks
open "$dest"
