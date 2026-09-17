# peek-ai-boo design

Notch app for watching Claude Code and Codex. Each session is a pixel ghost
left of the notch (coral Claude, mint Codex) animated by state, with a waiting
count on the right. Needs-you widens the island ~4s with a line like
`sync · needs approval: Bash npm test`, and chirps. Click to open approvals and
sessions, click a session to jump to its terminal. No agent tokens, no
CLAUDE.md edits, nothing leaves the Mac.

## Pieces

- `peekaboo-hook`: C++, `clang++ -O2`, no deps. Reads the payload, adds
  terminal info, sends one line, exits 0.
- `PeekAiBoo.app`: Swift 6.3, SwiftPM, Command Line Tools only, macOS 14
  minimum. Everything else. Carries the hook in `Contents/Helpers/`.
- `install.sh`: builds, installs, registers hooks.

Two borderless nonactivating NSPanels at `.statusBar`, canJoinAllSpaces,
fullScreenAuxiliary, stationary, ignoresCycle, LSUIElement. The pill is
fused to the notch, pure black, no outline, always up. Opening the island
orders in a second panel below it: Liquid Glass on macOS 26 (a plain system
material below that), a small gap under the pill, sized to its own
content. That means the gap and the space around the panel's rounded
corners are real desktop with no window over them, so a click there falls
straight through instead of being swallowed. Neither panel is ever key
except while the Other field is being edited, so the NSHostingView subclass
forwards mouseDown by hand the rest of the time — and, on the glass panel,
narrows hit testing to the rounded rect it actually draws, so its corners
pass clicks through too. Notch: `safeAreaInsets.top` by the gap between the
auxiliary top areas (32x185pt here). Built-in screen first, else a pill at
top center. One TimelineView runs all ghosts at ~10fps, paused when still.

## Protocol

`~/.peek-ai-boo/` (0700, or `$PEEKABOO_DIR`, short since AF_UNIX paths cap
near 104 bytes) holds `events.sock`, `decide.sock` and `bin/peekaboo-hook`,
which hook entries run. Decisions get their own socket so they never queue
behind events. Sockets: SOCK_STREAM, 0600, JSON lines, one connection per hook
run. At launch the app connects to `events.sock`. If that works another copy
is up and this one quits, else it unlinks and binds both.

```
{"v":1,"client":"claude","event":"PreToolUse","verb":"run","agent":"<session_id>",
 "tool":"Bash","tool_use_id":"toolu_...","prompt_id":"...","cwd":"/Users/m/src/sync",
 "transcript":"/Users/m/.claude/projects/.../<session_id>.jsonl","ts":1789811779123,
 "term":{"pid":4242,"tty":"/dev/ttys004","program":"ghostty","cmux_surface":"...",
 "cmux_workspace":"...","cmux_socket":"...","cmux_cli":"..."},"trunc":true,"hook":{...}}
```

- `client` is `--client`, `ts` is wall clock ms. The rest are copied from
  the payload (`agent` is `session_id`, `tool` is `tool_name`) and survive a
  dropped `hook`.
- `verb`: edit (Edit, Write, MultiEdit, NotebookEdit), read (Read), search
  (Grep, Glob), run (Bash), else think. Same as sync's hook.
- `path`: `tool_input.file_path`, else `notebook_path`, else `path`.
- `want`: `"decision"`, decide socket only.
- `term.pid`: the agent, walking up from `getppid()` past sh, bash, zsh, dash,
  env. `tty`: its tty (sysctl `KERN_PROC_PID`, `e_tdev`, `devname`). The rest:
  `TERM_PROGRAM`, `CMUX_SURFACE_ID`, `CMUX_WORKSPACE_ID`, `CMUX_SOCKET_PATH`,
  `CMUX_BUNDLED_CLI_PATH`.
- `trunc`: something was cut. `hook`: payload after the size pass, or null.

Empty strings and false flags are omitted. The app drops lines that don't
parse or lack `agent`.

Size pass: always read stdin to EOF (quitting early EPIPEs Claude), in one
streaming pass that only cuts inside strings. Top-level `tool_response` goes
null. Strings over 4 KiB are cut on a UTF-8 boundary, ending in `…`. Still
over 256 KiB, `hook` is null. The envelope comes from the same pass. Not an
object, not sent.

Silence: exit 0, stderr empty, stdout empty except a decision. SIGPIPE
ignored, nothing escapes main. Events get 2ms for connect plus write, and
every failure is silent. A run costs ~0.2ms over an empty spawn.

Decide:

1. Connect to `decide.sock`, silent on failure.
2. Send the line with `"want":"decision"`, `shutdown(SHUT_WR)`.
3. kqueue on the socket and `EVFILT_PROC NOTE_EXIT` for `term.pid`, no timer.
4. Agent gone, EOF, or a bad or 64 KiB+ reply: silent. Else print Claude's
   form, `message` copied as the raw token. A bare deny gets
   `Denied from peek-ai-boo.` Other `decision`s are silent.

```
{"decision":"allow"}   {"decision":"deny","message":"<text>"}
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"<text>"}}}
```

The entry's 3600s timeout is the cap. Then Claude kills the hook and the
terminal keeps waiting. Nothing auto-allows.

## Sessions

Keyed by `client` + `agent`, made on first event, so older sessions show up on
their next one.

| state | ghost | on |
|---|---|---|
| idle | floats, still after 20s | SessionStart |
| working | types | UserPromptSubmit, Pre/PostToolUse(Failure), PermissionDenied, SubagentStart/Stop, prompt resolved |
| needsYou | waves, badge | pending prompt, Notification `permission_prompt` |
| done | sleeps | Stop, Codex Interrupt |
| gone | removed | SessionEnd, `term.pid` exit (DispatchSource) |

`permission_prompt` lands ~6s into an unanswered prompt with no tool, so it
only backs the badge. Entering needsYou or done marks the session unseen,
chirps unless muted, and pings. Unseen, those two animate. Seen, they hold a
still frame and needsYou keeps its badge. Seen means you opened the island or
jumped there. The count is all needsYou sessions.

Which chirp plays is configurable: a handful of synthesized 8-bit presets
per event, picked and muted independently, plus one master volume, all set
from a small settings window off the right-click menu. Still no sound
files, same in-memory synthesis as everything else here.

A row has project (last part of `cwd`), agent, state, tool, elapsed and
tokens. Tool is `tool` plus a `tool_input` summary (command, path, URL,
pattern), set on PreToolUse, cleared on PostToolUse. Elapsed is from the last
UserPromptSubmit. Tokens are read from the transcript's last offset on each
event, no watcher or timer:

- Claude total: `message.usage` input + cache creation + cache read + output,
  deduped by `message.id`, last wins. Context: the last message's three input
  fields.
- Codex total: `info.total_token_usage.total_tokens` of the latest
  `token_count` event_msg. Context: `info.last_token_usage.input_tokens`.

## Approvals and questions

Claude only. A PermissionRequest (no `tool_use_id`) makes an Allow/Deny row
holding the decide connection. First of these resolves it, counting only a
later `ts`, since the sockets can deliver out of order:

- a click: reply, close.
- PostToolUse(Failure) in the session with the same `tool` and equal
  `tool_input`: the terminal answered.
- PreToolUse, PermissionDenied, UserPromptSubmit, Stop, SessionEnd in the
  session.

Anything but a click closes without a reply and the hook exits on EOF.
Claude leaves a blocked hook running when the terminal answers, so that and
the pid watch are the cleanup. If the hook closes first, the row says answer
in terminal until a signal lands. Click vs terminal: first to reach Claude
wins, the row goes on click, a failed write is ignored.

AskUserQuestion goes the same way. `tool_input.questions[]` is `{question,
header, options:[{label, description}], multiSelect}`. Hooks can't fill the
picker, so the notch answers with a deny carrying Claude's own answer text.
The picker shows in the terminal at the same time, and either one can answer.
Questions, and multiSelect labels inside the quotes, join with `, `.

```
User has answered your questions: "Which color?"="Red". You can now continue with the user's answers in mind.
```

Each question also gets an Other pill next to its options. Tap it for a
one-line field; Enter or the small send arrow commits, Esc cancels back to
the options. A multiSelect question adds the typed text alongside whatever's
picked; a single-choice one replaces the pick with it. Typed text is
flattened to one line, quotes and backslashes get escaped so they can't be
mistaken for the message's own quoting, length is capped at 200 characters,
and empty or whitespace-only text is rejected. Answering this way is what
makes the panel go key: it can otherwise never take keyboard focus, but it
becomes key for exactly as long as that field is focused, so typing doesn't
activate the app or pull focus off whatever terminal you were in. It resigns
key again the moment you submit or cancel.

## Terminal jump

First match wins.

1. cmux, if `cmux_surface` is set: `cmux select-workspace --workspace <id>`
   (if any), then `cmux focus-panel --panel <id>`, via `cmux_cli` with
   `CMUX_SOCKET_PATH=<cmux_socket>`. First, since cmux sets
   `TERM_PROGRAM=ghostty` too.
2. Ghostty: AppleScript, `every terminal whose working directory contains
   <cwd>`, `focus`.
3. Terminal.app: AppleScript, select the tab whose `tty` matches, window
   forward.
4. Else nothing, and the row says so.

AppleScript needs an Automation grant (NSAppleEventsUsageDescription), tied to
the signature.

## Install

`install.sh`: `make -C hook`, `scripts/build-app.sh` (release, hand-made bundle
and Info.plist, `codesign --sign -`), copy to `~/Applications`,
`PeekAiBoo --install-hooks`, open. `--uninstall-hooks` and the app menu run
the same Swift code.

Install copies the hook to `~/.peek-ai-boo/bin/`, then per config file backs
up to `<file>.peek-ai-boo.<unix time>.bak`, removes ours and adds ours, so
twice equals once. Ours: the command's first word ends in `/peekaboo-hook`.
Uninstall also drops matcher groups and event keys it left empty. Other
hooks stay. Command:
`peekaboo-hook --client <client>`, not async, so order holds.

- Claude, `~/.claude/settings.json`: SessionStart, UserPromptSubmit,
  PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest,
  PermissionDenied, Notification, Stop, SubagentStart, SubagentStop,
  SessionEnd. Timeout 5, PermissionRequest 3600.
- Codex, `~/.codex/hooks.json`, same shape: SessionStart, UserPromptSubmit,
  PreToolUse, PostToolUse, SubagentStart, SubagentStop, Stop, Interrupt,
  SessionEnd. Timeout 5, SessionEnd and Interrupt 3 (Codex's max). Codex
  trusts hooks by hash, so run `/hooks` after each change. `notify` stays
  untouched.

## Not in v1

Codex approvals (it gets mirror, ping, jump). Always allow (an allow with
`updatedPermissions` or `addRules` does nothing). Quota % (Claude has no local
source, Codex's is the plan window). iTerm2, VS Code, tmux. Subagent tokens.

## Sharp edges

- `term.pid` is a guess. A non-shell launcher gets picked instead.
- A hook that rewrites `tool_input` breaks terminal-answer matching.
- Questions over 4 KiB get quoted cut.
- Parallel calls and subagents share a session, so their PreToolUse resolves
  a prompt early. Drop that rule if it bites.
- A question answered from the notch leaves "Denied by PermissionRequest hook"
  in the terminal. Cosmetic, Claude carries on with the answer.
- Ad-hoc signing re-asks for Automation on every rebuild.
- Foundation drops key order, so settings.json comes back sorted. The backup
  has the original bytes.
- Deleting the app without uninstalling leaves entries that exit silently.
