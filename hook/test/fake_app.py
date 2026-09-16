"""Stand-in for PeekAiBoo.app's socket side, used by integration.py.

Stdlib only (python3.9, no 3.10+ syntax). One connection per hook run, same
as the real app, so these are single-shot helpers rather than a daemon:
bind, accept one connection, read one line, maybe reply, close.
"""
import os
import socket
import time


def bind_listen(path, backlog=16):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(path)
    os.chmod(path, 0o600)
    sock.listen(backlog)
    return sock


def _read_line(conn, timeout):
    conn.settimeout(timeout)
    buf = b""
    try:
        while b"\n" not in buf:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
    except socket.timeout:
        pass
    if not buf:
        return None
    return buf.split(b"\n", 1)[0].decode("utf-8", "surrogateescape")


def accept_one_line(sock, timeout=5):
    """Accepts one connection, reads it to the first newline (or EOF),
    closes it, and returns the line (without the newline), or None if
    nothing connected or nothing arrived."""
    sock.settimeout(timeout)
    try:
        conn, _ = sock.accept()
    except socket.timeout:
        return None
    with conn:
        return _read_line(conn, timeout)


def accept_and_hold(dir_path, hold_seconds, marker_path=None):
    """Accepts one decide.sock connection, reads its line, then sits on the
    open (unanswered) connection for `hold_seconds` before closing. Used to
    prove a hook exits on its own via the agent's pid dying rather than via
    EOF from this end.

    If given, `marker_path` is touched right after the line arrives -- by
    then the hook has already resolved its own term.pid, so whoever is
    waiting on the marker can kill the "agent" without racing that lookup.
    """
    path = os.path.join(dir_path, "decide.sock")
    sock = bind_listen(path)
    try:
        sock.settimeout(hold_seconds + 5)
        try:
            conn, _ = sock.accept()
        except socket.timeout:
            return None
        with conn:
            line = _read_line(conn, timeout=5)
            if marker_path is not None:
                with open(marker_path, "w"):
                    pass
            time.sleep(hold_seconds)
            return line
    finally:
        sock.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def reply_on_decide(dir_path, reply_bytes, timeout=5):
    """Binds decide.sock, accepts one connection, reads its line, sends
    `reply_bytes` unless it's None (a bare close, no reply at all), and
    returns the line that came in. Always unlinks the socket after."""
    path = os.path.join(dir_path, "decide.sock")
    sock = bind_listen(path)
    try:
        sock.settimeout(timeout)
        try:
            conn, _ = sock.accept()
        except socket.timeout:
            return None
        with conn:
            line = _read_line(conn, timeout)
            if reply_bytes is not None:
                try:
                    conn.sendall(reply_bytes)
                except OSError:
                    pass
            return line
    finally:
        sock.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
