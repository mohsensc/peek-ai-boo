#!/usr/bin/env python3
"""Stand-in for peekaboo-hook. Sends pre-built envelope lines over the unix
sockets so the app can be exercised without the real (C++) hook.

Usage:
  fake-hook.py send FILE.jsonl [--delay SECONDS]
  fake-hook.py event --event NAME --agent ID [--client claude] [--tool T]
      [--cwd DIR] [--pid N] [--tool-input JSON] [--hook JSON] [--decide]
"""
import argparse
import json
import os
import socket
import sys
import time


def peekaboo_dir():
    return os.environ.get("PEEKABOO_DIR") or os.path.join(os.environ["HOME"], ".peek-ai-boo")


def send_line(sock_path, obj):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    try:
        s.sendall((json.dumps(obj) + "\n").encode("utf-8"))
        if obj.get("want") == "decision":
            s.shutdown(socket.SHUT_WR)
            reply = b""
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                reply += chunk
            print(reply.decode("utf-8", "replace").rstrip("\n") if reply else "<EOF, no reply>")
    finally:
        s.close()


def cmd_send(args):
    d = peekaboo_dir()
    events = os.path.join(d, "events.sock")
    decide = os.path.join(d, "decide.sock")
    now = int(time.time() * 1000)
    with open(args.file) as f:
        for i, raw in enumerate(f):
            raw = raw.strip()
            if not raw:
                continue
            obj = json.loads(raw)
            obj.setdefault("v", 1)
            obj.setdefault("ts", now + i)
            sock_path = decide if obj.get("want") == "decision" else events
            try:
                send_line(sock_path, obj)
            except OSError as e:
                print("connect failed: %s" % e, file=sys.stderr)
                sys.exit(1)
            if args.delay:
                time.sleep(args.delay)


def cmd_event(args):
    d = peekaboo_dir()
    obj = {
        "v": 1,
        "client": args.client,
        "event": args.event,
        "agent": args.agent,
        "ts": int(time.time() * 1000),
    }
    if args.tool:
        obj["tool"] = args.tool
    if args.cwd:
        obj["cwd"] = args.cwd
    if args.pid is not None:
        obj["term"] = {"pid": args.pid}
    hook = {}
    if args.hook:
        hook.update(json.loads(args.hook))
    if args.tool_input:
        hook["tool_input"] = json.loads(args.tool_input)
    if hook:
        obj["hook"] = hook
    if args.decide:
        obj["want"] = "decision"

    sock_path = os.path.join(d, "decide.sock" if args.decide else "events.sock")
    try:
        send_line(sock_path, obj)
    except OSError as e:
        print("connect failed: %s" % e, file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_send = sub.add_parser("send")
    p_send.add_argument("file")
    p_send.add_argument("--delay", type=float, default=0)
    p_send.set_defaults(func=cmd_send)

    p_event = sub.add_parser("event")
    p_event.add_argument("--event", required=True)
    p_event.add_argument("--agent", required=True)
    p_event.add_argument("--client", default="claude")
    p_event.add_argument("--tool")
    p_event.add_argument("--cwd")
    p_event.add_argument("--pid", type=int)
    p_event.add_argument("--tool-input")
    p_event.add_argument("--hook")
    p_event.add_argument("--decide", action="store_true")
    p_event.set_defaults(func=cmd_event)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
