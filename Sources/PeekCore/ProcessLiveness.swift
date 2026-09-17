import Darwin

/// True if `pid` still exists. `kill(pid, 0)` sends no actual signal -- it
/// just asks the kernel whether we could -- so this is a safe, cheap check
/// to run occasionally rather than a live watch. ESRCH means the pid is
/// gone; EPERM means it's alive but owned by someone else, which still
/// counts as alive here since we're never going to signal it either way.
public func processIsAlive(_ pid: Int32) -> Bool {
    if kill(pid, 0) == 0 { return true }
    return errno != ESRCH
}
