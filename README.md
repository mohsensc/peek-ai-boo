https://github.com/user-attachments/assets/1a0ab858-1d41-4dad-8fba-34ee40b67b1a

# peek-ai-boo

A macOS notch app that watches your coding agents. Pixel ghosts sit in the
notch for every live Claude Code and Codex session. When one needs you, a
glass ping drops below the notch and stays until you deal with it.

Approve or deny a permission with a click. Answer a question right from the
notch, including typing your own answer. Jump to the session's terminal from
any ghost or ping. Chirps have a few sound presets, and any of it can be
muted.

Runs locally. Doesn't touch your agent's token usage. macOS 14 minimum; the
full Liquid Glass look needs macOS 26.

## Run it

```
./install.sh
```

Builds the hook and the app, drops the app in `~/Applications`, and
registers the hook with Claude Code and (if present) Codex. In Codex, run
`/hooks` once afterward so it trusts the new entries.

## Broken

- Ad-hoc signing means macOS asks for the Automation permission again on
  every rebuild.
- No auto-update: rerun `./install.sh` to pick up a new build.
- Uninstalling (`--uninstall-hooks`, or the island's right-click menu)
  drops the hook registration but leaves the app and `~/.peek-ai-boo` in
  place.
- No Codex approvals yet (mirror, ping, and jump only), no always-allow, no
  quota percentage, no iTerm2/VS Code/tmux, no subagent tokens.
- See [docs/design.md](docs/design.md) for the rest of what's not in v1.
