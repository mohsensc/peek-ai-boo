"""Drives the built hook end to end: sockets, timing, process death.

Stdlib only (python3.9, no 3.10+ syntax). Run as:
    python3 test/integration.py <path-to-hook-binary>
Prints "hook integration: N passed" only if every check passed; otherwise
prints the failures and exits nonzero.
"""
import json
import os
import random
import socket
import string
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fake_app  # noqa: E402

HOOK = sys.argv[1]

_passed = 0
_failures = []


def check(name, cond, detail=""):
    global _passed
    if cond:
        _passed += 1
    else:
        _failures.append(name + (": " + detail if detail else ""))


def run_dir():
    return tempfile.mkdtemp(prefix="pab.")


def run_hook(stdin_bytes, client="claude", dir_path=None, timeout=5, extra_env=None):
    env = dict(os.environ)
    if dir_path is not None:
        env["PEEKABOO_DIR"] = dir_path
    if extra_env:
        env.update(extra_env)
    args = [HOOK]
    if client is not None:
        args += ["--client", client]
    start = time.monotonic()
    proc = subprocess.run(args, input=stdin_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           env=env, timeout=timeout)
    elapsed = time.monotonic() - start
    return proc, elapsed


def basic_payload(event="PreToolUse", session_id="sess1", tool_name="Bash", cwd="/tmp/x", **extra):
    payload = {
        "hook_event_name": event,
        "session_id": session_id,
        "tool_name": tool_name,
        "cwd": cwd,
        "tool_input": {"command": "ls"},
    }
    payload.update(extra)
    return json.dumps(payload).encode()


# basic event

def test_basic_event():
    d = run_dir()
    sock = fake_app.bind_listen(os.path.join(d, "events.sock"))
    result = {}
    t = threading.Thread(target=lambda: result.__setitem__("line", fake_app.accept_one_line(sock, timeout=3)))
    t.start()
    proc, _ = run_hook(basic_payload(), dir_path=d)
    t.join(timeout=3)
    sock.close()

    line = result.get("line")
    check("basic_event.line_received", line is not None)
    if line is None:
        return
    try:
        obj = json.loads(line)
        check("basic_event.valid_json", True)
    except ValueError as e:
        check("basic_event.valid_json", False, str(e))
        return
    check("basic_event.v", obj.get("v") == 1, repr(obj.get("v")))
    check("basic_event.client", obj.get("client") == "claude")
    check("basic_event.event", obj.get("event") == "PreToolUse")
    check("basic_event.agent", obj.get("agent") == "sess1")
    check("basic_event.tool", obj.get("tool") == "Bash")
    check("basic_event.cwd", obj.get("cwd") == "/tmp/x")
    check("basic_event.verb", obj.get("verb") == "run", repr(obj.get("verb")))
    check("basic_event.stdout_empty", proc.stdout == b"", repr(proc.stdout))
    check("basic_event.stderr_empty", proc.stderr == b"", repr(proc.stderr))
    check("basic_event.exit0", proc.returncode == 0)


# no socket at all

def test_no_socket():
    d = run_dir()
    proc, elapsed = run_hook(basic_payload(), dir_path=d)
    check("no_socket.exit0", proc.returncode == 0)
    check("no_socket.no_stdout", proc.stdout == b"")
    check("no_socket.no_stderr", proc.stderr == b"")
    check("no_socket.under_50ms", elapsed < 0.05, "%.1fms" % (elapsed * 1000))


# listener bound but never accepts

def test_listener_never_accepts():
    d = run_dir()
    sock = fake_app.bind_listen(os.path.join(d, "events.sock"))
    try:
        proc, elapsed = run_hook(basic_payload(), dir_path=d)
        check("never_accepts.exit0", proc.returncode == 0)
        check("never_accepts.under_30ms", elapsed < 0.03, "%.1fms" % (elapsed * 1000))
    finally:
        sock.close()


# 5 MiB stdin, no listener

def test_5mib_stdin():
    d = run_dir()
    huge = "A" * (5 * 1024 * 1024)
    payload = json.dumps({
        "hook_event_name": "Notification", "session_id": "big1", "tool_response": huge,
    }).encode()
    try:
        proc, _ = run_hook(payload, dir_path=d, timeout=10)
        check("five_mib.no_broken_pipe", True)
    except BrokenPipeError as e:
        check("five_mib.no_broken_pipe", False, str(e))
        return
    check("five_mib.exit0", proc.returncode == 0)


# 200 random nested payloads

_EMOJI_LO, _EMOJI_HI = 0x1F300, 0x1F64F
_CJK_LO, _CJK_HI = 0x4E00, 0x9FFF


def _random_string(rng, max_len):
    n = rng.randint(0, max_len)
    pools = [
        lambda: rng.choice(string.ascii_letters + string.digits + " _-./\"\\\n"),
        lambda: chr(rng.randint(0x00C0, 0x024F)),
        lambda: chr(rng.randint(_CJK_LO, _CJK_HI)),
        lambda: chr(rng.randint(_EMOJI_LO, _EMOJI_HI)),
    ]
    return "".join(rng.choice(pools)() for _ in range(n))


def _random_value(rng, depth):
    if depth <= 0 or rng.random() < 0.4:
        choice = rng.random()
        if choice < 0.5:
            return _random_string(rng, rng.choice([5, 50, 500, 5000, 9000]))
        if choice < 0.7:
            return rng.randint(-10**9, 10**9)
        if choice < 0.85:
            return rng.choice([True, False])
        return None
    if rng.random() < 0.5:
        return [_random_value(rng, depth - 1) for _ in range(rng.randint(0, 4))]
    return {_random_string(rng, 10) or "k": _random_value(rng, depth - 1) for _ in range(rng.randint(0, 4))}


def _max_string_bytes(value):
    if isinstance(value, str):
        return len(value.encode("utf-8"))
    if isinstance(value, dict):
        return max([_max_string_bytes(v) for v in value.values()] + [0])
    if isinstance(value, list):
        return max([_max_string_bytes(v) for v in value] + [0])
    return 0


_RANDOM_PAYLOADS_SEED = 20260916


def test_random_payloads(n=200):
    # events.sock has no delivery guarantee -- design.md gives it 2ms for
    # connect plus write and calls a miss silent, so on a loaded box some
    # of these (deliberately oversized) payloads legitimately never make it
    # over the wire. That's expected, not a scanner bug, so it's checked as
    # a floor (90%, well under the worst seen in practice -- 196/200 across
    # dozens of runs while pinning this down), not an exact count. What
    # must always hold is the thing this test actually exists to catch: a
    # line the hook did finish sending is well-formed JSON, every time --
    # the protocol is newline-terminated lines, so a send cut short by the
    # budget shows up to fake_app as no line at all, never a truncated one
    # (see fake_app._read_line), and can't land here as a parse failure.
    d = run_dir()
    sock = fake_app.bind_listen(os.path.join(d, "events.sock"))
    rng = random.Random(_RANDOM_PAYLOADS_SEED)
    delivered = 0
    corrupt = 0
    worst = 0
    try:
        for i in range(n):
            payload = {
                "hook_event_name": "PreToolUse",
                "session_id": "rand-%d" % i,
                "tool_name": "Bash",
                "cwd": "/tmp",
                "tool_input": {"command": _random_string(rng, 9000), "nested": _random_value(rng, 3)},
                "tool_response": _random_value(rng, 3),
                "extra": _random_value(rng, 4),
            }
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            result = {}
            t = threading.Thread(target=lambda: result.__setitem__("line", fake_app.accept_one_line(sock, timeout=3)))
            t.start()
            proc, _ = run_hook(data, dir_path=d)
            t.join(timeout=3)
            if proc.returncode != 0:
                continue
            line = result.get("line")
            if line is None:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                corrupt += 1
                continue
            delivered += 1
            worst = max(worst, _max_string_bytes(obj.get("hook")))
    finally:
        sock.close()
    check("random_payloads.no_corrupt_lines", corrupt == 0,
          "%d corrupt, seed=%d" % (corrupt, _RANDOM_PAYLOADS_SEED))
    check("random_payloads.delivery_floor", delivered >= n * 0.9,
          "%d/%d delivered, seed=%d" % (delivered, n, _RANDOM_PAYLOADS_SEED))
    check("random_payloads.cut_bound", worst <= 4096 + 3, "worst=%d" % worst)


# decide replies

def _decide_payload(session_id="perm1", tool_name="Bash"):
    return json.dumps({
        "hook_event_name": "PermissionRequest",
        "session_id": session_id,
        "tool_name": tool_name,
        "tool_input": {"command": "npm test"},
    }).encode()


def _run_decide(d, reply_bytes, timeout=5):
    result = {}
    t = threading.Thread(target=lambda: result.__setitem__(
        "line", fake_app.reply_on_decide(d, reply_bytes, timeout=timeout)))
    t.start()
    proc, elapsed = run_hook(_decide_payload(), dir_path=d, timeout=timeout + 2)
    t.join(timeout=timeout + 2)
    return proc, result.get("line"), elapsed


def test_decide_allow():
    d = run_dir()
    proc, line, _ = _run_decide(d, b'{"decision":"allow"}\n')
    check("decide_allow.request_seen", line is not None)
    expected = b'{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n'
    check("decide_allow.stdout", proc.stdout == expected, repr(proc.stdout))
    check("decide_allow.stderr_empty", proc.stderr == b"")
    check("decide_allow.exit0", proc.returncode == 0)


def test_decide_deny_with_message():
    d = run_dir()
    message = "no \"quotes\" and \\backslash\\ and\nnewline and emoji \U0001F600"
    reply = json.dumps({"decision": "deny", "message": message}).encode()
    proc, line, _ = _run_decide(d, reply + b"\n")
    check("decide_deny_msg.request_seen", line is not None)
    expected = (
        '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":'
        + json.dumps(message) + "}}}\n"
    ).encode()
    check("decide_deny_msg.stdout", proc.stdout == expected, repr(proc.stdout))
    check("decide_deny_msg.exit0", proc.returncode == 0)


def test_decide_bare_deny():
    d = run_dir()
    proc, line, _ = _run_decide(d, b'{"decision":"deny"}\n')
    check("decide_bare_deny.request_seen", line is not None)
    expected = (b'{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":'
                b'{"behavior":"deny","message":"Denied from peek-ai-boo."}}}\n')
    check("decide_bare_deny.stdout", proc.stdout == expected, repr(proc.stdout))


def test_decide_bad_replies():
    d = run_dir()
    for label, reply in [
        ("maybe", b'{"decision":"maybe"}\n'),
        ("garbage", b"not json at all {{{\n"),
        ("no_reply", None),
        ("oversized", (b'{"decision":"deny","message":"' + b"A" * (70 * 1024) + b'"}\n')),
    ]:
        proc, _, _ = _run_decide(d, reply, timeout=3)
        check("decide_bad.%s.stdout_empty" % label, proc.stdout == b"", repr(proc.stdout[:80]))
        check("decide_bad.%s.exit0" % label, proc.returncode == 0)


# the agent dies while a decision is pending

def test_agent_dies():
    d = run_dir()
    marker = os.path.join(d, "seen")
    held = {}
    hold_thread = threading.Thread(
        target=lambda: held.__setitem__("line", fake_app.accept_and_hold(d, hold_seconds=2, marker_path=marker)))
    hold_thread.start()
    time.sleep(0.1)  # let the listener bind before the middle process connects

    # The middle process waits for `marker` -- written once decide.sock has
    # the request -- before dying, so the hook has already resolved its own
    # term.pid (from the still-alive middle process) before this exits.
    # Without that wait, os._exit() often beats the hook to getppid() and
    # the hook silently gets reparented to launchd instead.
    middle_src = (
        "import subprocess, sys, os, time\n"
        "p = subprocess.Popen([%r, '--client', 'claude'], stdin=subprocess.PIPE, "
        "stdout=open(os.devnull, 'wb'), stderr=open(os.devnull, 'wb'), "
        "env=dict(os.environ, PEEKABOO_DIR=%r))\n"
        "p.stdin.write(%r)\n"
        "p.stdin.close()\n"
        "print(p.pid)\n"
        "sys.stdout.flush()\n"
        "deadline = time.monotonic() + 3\n"
        "while not os.path.exists(%r) and time.monotonic() < deadline:\n"
        "    time.sleep(0.005)\n"
        "os._exit(0)\n"
    ) % (HOOK, d, _decide_payload(), marker)
    out = subprocess.check_output([sys.executable, "-c", middle_src], timeout=8)
    hook_pid = int(out.strip())

    deadline = time.monotonic() + 0.2
    gone = False
    while time.monotonic() < deadline:
        try:
            os.kill(hook_pid, 0)
        except ProcessLookupError:
            gone = True
            break
        time.sleep(0.005)
    check("agent_dies.hook_exited_within_200ms", gone)
    hold_thread.join(timeout=3)


# shell-skipping walk against the real process tree

def test_shell_walk_real():
    d = run_dir()
    sock = fake_app.bind_listen(os.path.join(d, "events.sock"))
    result = {}
    t = threading.Thread(target=lambda: result.__setitem__("line", fake_app.accept_one_line(sock, timeout=3)))
    t.start()
    cmd = "%s --client claude" % HOOK
    proc = subprocess.run(["sh", "-c", cmd], input=basic_payload(), stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, env=dict(os.environ, PEEKABOO_DIR=d), timeout=5)
    t.join(timeout=3)
    sock.close()
    line = result.get("line")
    check("shell_walk.line_received", line is not None)
    if line is None:
        return
    obj = json.loads(line)
    check("shell_walk.pid_is_this_process", obj.get("term", {}).get("pid") == os.getpid(),
          "got %r want %r" % (obj.get("term", {}).get("pid"), os.getpid()))
    check("shell_walk.exit0", proc.returncode == 0)


# client flag handling

def test_client_codex():
    d = run_dir()
    sock = fake_app.bind_listen(os.path.join(d, "events.sock"))
    result = {}
    t = threading.Thread(target=lambda: result.__setitem__("line", fake_app.accept_one_line(sock, timeout=3)))
    t.start()
    proc, _ = run_hook(basic_payload(), client="codex", dir_path=d)
    t.join(timeout=3)
    sock.close()
    line = result.get("line")
    check("client_codex.line_received", line is not None)
    if line is not None:
        check("client_codex.field", json.loads(line).get("client") == "codex")
    check("client_codex.exit0", proc.returncode == 0)


def test_client_missing_or_unknown():
    d = run_dir()
    sock = fake_app.bind_listen(os.path.join(d, "events.sock"))
    for client in (None, "gpt5"):
        result = {}
        t = threading.Thread(target=lambda: result.__setitem__("line", fake_app.accept_one_line(sock, timeout=0.3)))
        t.start()
        proc, _ = run_hook(basic_payload(), client=client, dir_path=d)
        t.join(timeout=1)
        label = "missing" if client is None else "unknown"
        check("client_%s.nothing_sent" % label, result.get("line") is None)
        check("client_%s.exit0" % label, proc.returncode == 0)
        check("client_%s.silent" % label, proc.stdout == b"" and proc.stderr == b"")
    sock.close()


# 200 runs, no socket, timed

def test_200_runs_timed():
    d = run_dir()
    start = time.monotonic()
    all_ok = True
    for _ in range(200):
        proc, _ = run_hook(basic_payload(), dir_path=d)
        if proc.returncode != 0:
            all_ok = False
    elapsed = time.monotonic() - start
    check("200_runs.all_exit0", all_ok)
    check("200_runs.under_2s", elapsed < 2.0, "%.3fs" % elapsed)
    per_run_ms = (elapsed / 200) * 1000
    print("latency: 200 runs with no listener, %.3fs total, %.2fms/run" % (elapsed, per_run_ms))


# link check

def test_otool_deps():
    out = subprocess.check_output(["otool", "-L", HOOK]).decode()
    lines = [l.strip() for l in out.splitlines()[1:] if l.strip()]
    names = [l.split(" (")[0] for l in lines]
    bad = [n for n in names if "libc++" not in n and "libSystem" not in n]
    check("otool.only_libcxx_and_libsystem", not bad, repr(bad))


TESTS = [
    test_basic_event,
    test_no_socket,
    test_listener_never_accepts,
    test_5mib_stdin,
    test_random_payloads,
    test_decide_allow,
    test_decide_deny_with_message,
    test_decide_bare_deny,
    test_decide_bad_replies,
    test_agent_dies,
    test_shell_walk_real,
    test_client_codex,
    test_client_missing_or_unknown,
    test_200_runs_timed,
    test_otool_deps,
]


def main():
    for test in TESTS:
        try:
            test()
        except Exception as e:  # keep going, report everything at once
            _failures.append("%s: raised %r" % (test.__name__, e))

    if _failures:
        for f in _failures:
            print("FAIL " + f)
        print("hook integration: %d passed, %d failed" % (_passed, len(_failures)))
        sys.exit(1)

    print("hook integration: %d passed" % _passed)


if __name__ == "__main__":
    main()
