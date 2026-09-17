# peek-ai-boo design

Notch app for watching Claude Code and Codex. Each session is a pixel ghost
left of the notch (coral Claude, mint Codex) animated by state, with a waiting
count on the right. The pill itself never resizes; a session that needs you
chirps and drops a small glass capsule below the pill instead. Click the pill
to open the full panel (approvals and sessions), click a session to jump to
its terminal. No agent tokens, no CLAUDE.md edits, nothing leaves the Mac.

## Pieces

- `peekaboo-hook`: C++, `clang++ -O2`, no deps. Reads the payload, adds
  terminal info, sends one line, exits 0.
- `PeekAiBoo.app`: Swift 6.3, SwiftPM, Command Line Tools only, macOS 14
  minimum. Everything else. Carries the hook in `Contents/Helpers/`.
- `install.sh`: builds, installs, registers hooks.

Three borderless nonactivating NSPanels at `.statusBar`, canJoinAllSpaces,
fullScreenAuxiliary, stationary, ignoresCycle, LSUIElement. The pill is
fused to the notch, pure black, no outline, always up, fixed size. Below it,
in the same slot, sits either the ping stack (persistent capsules, see
below) or, once clicked, the full panel: Liquid Glass on macOS 26 (a plain
system material below that), a small gap under the pill, sized to its own
content. Only one of the two shows at a time — opening the panel hides the
ping stack, since the panel already lists every pending prompt itself. That
means the gap, and the space around whichever one's rounded corners, are
real desktop with no window over them, so a click there falls straight
through instead of being swallowed. On the ping stack, several capsules (and
their gaps) share one window, so hit-testing checks each capsule's own
rounded rect rather than treating the whole window as one shape — same idea
as the panel's corner narrowing, just per-row. None of the three panels is
ever key except while an Other field is being edited (routed to whichever of
the panel/ping-stack is currently showing question cards), so the
NSHostingView subclass forwards mouseDown by hand the rest of the time.
Notch: `safeAreaInsets.top` by the gap between the auxiliary top areas
(32x185pt here). Built-in screen first, else a pill at top center. One
TimelineView animates the ghosts, at whatever rate the fastest currently-
moving pose actually needs (up to 4fps for needsYou) rather than a flat
10fps for all of them — the flat rate was the real cost of a session sitting
in `working` or `idle`, worth over 1% CPU for nothing. Paused entirely when
nothing's moving. needsYou itself only counts as moving for a short wave
(`Session.needsYouWaveMs`, 5s) from whatever ping caused it — see Sessions —
so an approval nobody's answered yet settles back to ~0% CPU instead of
waving at 4fps indefinitely.

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
| needsYou | waves for 5s then holds, badge | pending prompt, Notification `permission_prompt` |
| done | sleeps | Stop, Codex Interrupt |
| gone | removed | SessionEnd, `term.pid` exit (DispatchSource) |

`permission_prompt` lands ~6s into an unanswered prompt with no tool, so it
only backs the badge. Entering needsYou or done marks the session unseen and
chirps unless muted. Unseen, done animates for as long as it stays unseen —
same as before. needsYou is shorter-lived: it plays its wave for
`Session.needsYouWaveMs` (5s) from whatever ping caused it
(`needsYouWaveStart`), then holds the needs-you pose on frame 0 even though
still unseen — no timer keeps running to get there, `isMoving` is just a
pure function of elapsed time, and `AppModel.scheduleStillCheck` arms one
`asyncAfter` for the moment it flips so the pill's TimelineView can pause
instead of polling. A new pending prompt on an already-waiting session (a
second ping stacking on the first) restarts the wave, even when the
session's own state doesn't change. Seen, both needsYou and done hold a
still frame regardless of the wave, and needsYou keeps its badge either way.
Seen means you opened the island, jumped there, or (done only) clicked its
info ping — see Pings. A faded info ping doesn't mark its session seen by
itself; the ghost just keeps animating unseen, same as if the ping had
never shown up. The count is all needsYou sessions.

The pill's own ghost row only ever shows live sessions (gone means removed
from `sessions`, not hidden), capped at `PillGhostLayout.visibleSlots` (4 —
measured from the pill's fixed 110pt wing beside the notch at 13pt ghosts
and 4pt spacing, with room held for the badge below). Past the cap, the rest
collapse into a small circle badge, "+K", right after the last ghost.
Priority for the slots: needsYou first, then working, then most recent
activity — a session waiting on you is never one of the ones folded into K.
Clicking the badge opens the full panel. `PillGhostLayout.selectShown` is
the pure version of this; `AnimatedGhostRow` just draws whatever it returns.

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

## Pings

A ping is a small Liquid Glass row that springs down below the pill — never
the pill itself. Collapsed, it's two thin lines in a rounded rect with
concentric corners, not a one-line capsule: tight line spacing, minimal
vertical padding (the exact numbers live in `PingStackLayout`, shared with
AppKit's own sizing and hit-testing so a click and a pixel never disagree).
Up to 3 stack vertically, oldest (longest-blocked) first; a 4th collapses
the rest into one "+N more" capsule — that one's still a single line and a
true capsule, since it has no session or request to give a second line to.
Persistence depends on kind:

- **Approval/question** (one per pending prompt — see Approvals and
  questions): stays until that prompt resolves, by any of the same paths a
  panel row resolves by (a click here, a click in the panel, or the
  terminal). Resolving elsewhere animates the capsule away.
- **Info** (a done, unseen session): fades on its own after
  `PingStackLayout.doneFadeMs` (2.5s), measured from the session's
  `lastEvent` — a pure function of elapsed time, same idea as the needsYou
  wave, not a per-view timer. No click needed, but the whole capsule is
  still clickable while it's up and jumps to that session's terminal
  (`PingActions.jump`, same path a session row uses), which is what keeps
  "always be able to link to the terminal" true even though there's no
  terminal button on it. That jump also runs `markSeen`, same as ever;
  the ghost still animates by the ordinary seen/unseen rules regardless of
  whether the ping itself has faded. Done pings never count toward the
  stack's "+N more" and never bump an approval or question out of a
  guaranteed slot — `PingStackLayout.selectShown` gives blocking prompts up
  to `visibleLimit` first and only lets done pings fill what's left over.

Every capsule and card carries a terminal button (TerminalJump, same as a
session row) and the session's ghost, static — the pill already animates
that session, so a second animated copy here would undo the point of
keeping this cheap. The ghost sits in its own leading column, vertically
centered against the row(s) beside it. A done ping is the exception: one
line, no row 2, no buttons at all — just the ghost and "session · done" —
since there's nothing to answer and nowhere it needs to grow.

A collapsed approval/question row is two lines beside that ghost. Row 1:
session name (semibold, truncating first — see below), then "· " and a
short kind word ("needs approval", "asks", "asks · N", "done"), then
whatever buttons that kind gets, wrapped together with the kind word in a
`fixedSize` cluster so it never gives up space to the name. Small circular
glass buttons with SF Symbols, sized to row 1 rather than the panel's usual
24pt: an approval gets terminal plus deny (✗) and allow (✓, green glass);
hookGone shows "answer in terminal" text instead of deny/allow. Row 2: the
request or message alone (the command or the question), full width,
middle-truncated only if it still doesn't fit — so a long shell command or
question keeps both ends visible instead of just its start. Answering an
approval goes through the exact same Approvals.answer / ApprovalDesk.answer
path a panel row's buttons use, so "answered once, never after resolution"
is one guarantee, not two.

**Truncation priority**: row 1's session name is the one side that gives up
space. The kind word and its buttons draw at their own natural width
(`fixedSize`, `layoutPriority(1)`) regardless of how wide the real glass
buttons render — macOS 26 draws them wider than the frame they're asked
for — so a long session name is what truncates, never "needs approval"
clipping to "needs appro…". `PingRowOneBudget` in PeekCore is a rough,
testable sanity check on this (reserved cluster width plus a minimum name
width), not a claim about exact pixels.

A question ping's row 2 is always the question itself; row 1 depends on
`Question.fitsInline` (exactly two single-select options, short enough
combined — see `PingStackLayout`'s budget above):

- **Fits inline**: row 1 draws both options as small direct-answer buttons
  plus ✎ for Other, in the slot an approval's deny/allow would take. ✎
  turns green (`isOpen || committed`, so it stays that way through typing,
  not just once sent) and opens row 3 — a native text field plus a send
  arrow, appended under row 2, growing the capsule by
  `PingStackLayout.rowThreeHeight`. Enter (or the arrow) sends; Esc, or ✎
  again, collapses row 3 without answering. Row 3 isn't part of the
  tappable body — only row 1/row 2 expand to the card.
- **Doesn't fit** (3+ options, multiSelect, or options too wide): row 1
  just says "asks · N" (`Question.expandCount`: every option across every
  question) plus a chevron that expands to the card, same as tapping the
  body anywhere else.

Tapping the body of either shape — anywhere on row 1 or row 2 — morphs it
into the same expanded card: header (ghost, project, collapse, terminal) on
top, the question(s) and their context scrolling in the middle, answers —
including Other and its text field — pinned at the bottom so they never
scroll out of reach. Other's pill turns green the same way as the inline
✎ (`isOpen || committed`), for the same reason. Multi-select toggles
options green and answers all of them, typed Other included, through one
Send button. The card's height is capped at a fraction of the screen's
visible height (`PingCardHeight`); only the context area scrolls, the
header and footer never shrink.

Reduce Motion drops the spring/morph animations; Reduce Transparency drops
to the same plain-material fallback every other glass surface here uses
(`GlassCompat`).

Every "green" above is system green (`NSColor.systemGreen`), not the accent
color — tinted glass rendered as flat gray under this Mac's accent setting,
system green doesn't, and it still adapts to light/dark on its own. One
constant, `GlassCompat.confirmTint`, backs every confirm/selected state:
Allow, Send, a picked option, Other while open or committed. Everything
else stays neutral glass.

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

## Screenshot flags

For scripts that can't send the island a synthetic click:

- `--open`: starts with the full panel open.
- `--open-other`: opens the first question's Other field the moment one
  shows up.
- `--other-text <text>`: paired with `--open-other`, also types `text` into
  the field it just opened — the inline row 3 or the card, whichever is
  showing.
- `--expand-ping`: morphs the first question ping straight to its card.
- `--preselect-multi`: ticks the first two options of the first multiSelect
  question once its card is up — a screenshot script can't reach a card's
  own `@State` picks any other way.
- `--open-settings`: opens Settings, raised to `.floating` since an
  accessory-policy app doesn't reliably win z-order over whatever already
  has focus (which a screenshot script always does).
- `--open-settings-normal`: same, but through the exact path the menu item
  uses — no raise. For confirming Settings really does sit at the standard
  window level in normal use, not just reading the source and trusting it.
- `--print-geometry`: prints the pill/panel/ping-stack/Settings frames (and
  their window level) to stdout after every relayout, plus a same-process
  AppKit hitTest check at each ping capsule's center and at the midpoint of
  every gap between them. A capture script reads the frames to
  `screencapture -R` just the relevant rect.

## Shapes

No square corners. Every rect is a continuous rounded rect
(`RoundedRectangle(cornerRadius:style: .continuous)` or `ConcentricRectangle`
inside something with a `containerShape`) or a capsule/circle — the one
exception is the pixel ghost sprites, which keep their square pixels on
purpose. Borders are a hairline separator at most, usually none; the glass
edge does the work an outline would. Anything that draws its own content
inside a shape (a scrolled question card, a collapsed ping row) clips to
that same shape instead of trusting the glass background to do it, since
`.glassEffect`/`.background` draw behind content, not around it.

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
