# peek-ai-boo

A macOS notch app. Little pixel ghosts sit in the notch and track your
coding agents: Claude Code and Codex. When Claude Code needs a
permission decision, you answer it right there from the notch.

Runs locally. Doesn't touch your agent's token usage.

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
- See [docs/design.md](docs/design.md) for what's not in v1 at all yet.
