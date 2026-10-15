#!/usr/bin/env python3
"""Run one command under a deadline, killing its whole process tree on expiry.

`GNU timeout` covers Linux, but macOS has no `timeout` and Git Bash resolves
Windows' unrelated `timeout.exe`, so a shell-level bound is not portable. This
wrapper exists because the native acceptance suite has wedged on the runners:
every thread parks on a futex with no runnable thread, the log stops mid-suite, and
without a bound the job burns its entire timeout and ends with no diagnosis.

The whole process group must die, not just the direct child. On POSIX the command
leads its own session, so one `killpg` reaches every process that stayed in it; on
Windows `taskkill /T` walks the tree. A descendant that deliberately starts its OWN
session (`setsid`) escapes that group, exactly as the bounded-process tests document
for the supervisor path, and is not claimed here.

Exit code 124 on expiry mirrors `timeout(1)`, so callers can tell a timeout from a
genuine non-zero exit.
"""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time

TIMEOUT_EXIT_CODE = 124

# How long a TERM'd command may take to shut down before the group is killed, the
# same grace `timeout --kill-after=60` provided. Overridable so tests can exercise
# escalation without waiting a minute per case.
GRACE_SECONDS = 60


def _grace_seconds() -> int:
    raw = os.environ.get("CJDOC_TIMEOUT_GRACE_SECONDS")
    if raw is None:
        return GRACE_SECONDS
    try:
        value = int(raw)
    except ValueError:
        print(f"run_with_timeout.py: ignoring non-numeric grace {raw!r}", file=sys.stderr)
        return GRACE_SECONDS
    return value if value > 0 else GRACE_SECONDS


def _signal_group(process: subprocess.Popen, signum: int) -> None:
    """Signal the command's whole group, falling back to the direct child."""
    if os.name == "posix":
        try:
            os.killpg(process.pid, signum)
            return
        except OSError:
            # The group may already be gone; fall back to the direct child.
            try:
                process.send_signal(signum)
            except OSError:
                pass
        return
    # Windows has no graceful group signal. `Popen.terminate()` would
    # `TerminateProcess` the LEADER only, and once that PID is gone `taskkill /T`
    # can no longer discover the descendants started by it -- a surviving
    # `std.testrunner` would be left behind. So nothing is signalled here and the
    # forced `taskkill /T` in `_kill_tree` runs while the leader is still alive and
    # can still be walked.
    return


def _kill_tree(process: subprocess.Popen) -> None:
    if os.name == "posix":
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            # The group may already be gone; fall back to the direct child.
            try:
                process.kill()
            except OSError:
                pass
        return
    _terminate_windows_tree_now(process)


def _wait_for_group(process: subprocess.Popen, seconds: int) -> None:
    """Wait out the grace for the whole group, not just the leader.

    `Popen.wait()` returns as soon as the LEADER exits, and a worker in the same
    session can still be flushing results or running its own TERM handler. Killing
    the group at that moment would deny it the grace the leader was given, so the
    wait continues while any process still holds the group.
    """
    deadline = time.monotonic() + seconds
    # The leader exiting is recorded so a zombie group leader cannot keep this loop
    # busy forever, but it does not end the wait on its own.
    while time.monotonic() < deadline:
        process.poll()
        if not _group_is_alive(process):
            return
        time.sleep(0.05)
    process.poll()


def _terminate_windows_tree_now(process: subprocess.Popen) -> None:
    """End the tree on Windows while its root still exists.

    `taskkill /T` walks from the given PID, so the root must still be present when it
    runs. Waiting out the grace here would let the root exit naturally and leave a
    worker undiscoverable, so the tree is terminated immediately instead.
    """
    subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if process.poll() is None:
        try:
            process.kill()
        except OSError:
            pass


def _group_is_alive(process: subprocess.Popen) -> bool:
    """Whether any process still belongs to the command's session/group."""
    if os.name == "nt":
        # No signal-0 equivalent for a tree; the job object is what bounds it, so
        # fall back to the leader's state.
        return process.poll() is None
    try:
        os.killpg(process.pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # The group exists but is not ours to signal; treat it as alive.
        return True
    except OSError:
        return process.poll() is None


def _start_with_signal_cleanup(command: list[str]) -> subprocess.Popen:
    """Start the command with cancellation cleanup installed before spawning.

    `check.sh` and its parent jobs send SIGTERM on cancellation. Without this the
    wrapper exits while the command keeps running in its own session, so `cjpm test`
    survives as an orphan and continues mutating fixture and build outputs under the
    next run.
    """
    previous: dict = {}
    process: subprocess.Popen | None = None
    pending: list = []

    def handler(signum, frame) -> None:
        if process is None:
            # Popen may have spawned the child before returning its handle.
            # Defer cancellation until the group can be signalled and reaped.
            pending.append((signum, frame))
            return
        _signal_group(process, signal.SIGTERM)
        if os.name == "nt":
            _terminate_windows_tree_now(process)
        else:
            _wait_for_group(process, _grace_seconds())
            # The group is killed even when the leader obeyed TERM, because a worker
            # in its session may not have, and the grace above already covered it.
            _kill_tree(process)
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            pass
        prior = previous.get(signum, signal.SIG_DFL)
        if prior == signal.SIG_IGN:
            return
        if callable(prior):
            prior(signum, frame)
            return
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    # SIGHUP too: a local run that loses its terminal or SSH session receives it,
    # and the command -- in its own session -- would not, so it would survive as an
    # orphan mutating build and fixture outputs.
    handled = [signal.SIGTERM, signal.SIGINT]
    if hasattr(signal, "SIGHUP"):
        handled.append(signal.SIGHUP)
    for signum in handled:
        try:
            previous[signum] = signal.signal(signum, handler)
        except (ValueError, OSError):
            pass
    try:
        process = subprocess.Popen(
            command,
            start_new_session=os.name == "posix",
            creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
            if os.name == "nt" else 0,
        )
    except BaseException:
        # No handle was returned. Restore signal semantics even when launch fails.
        for signum, prior in previous.items():
            signal.signal(signum, prior)
        for signum, _ in pending:
            os.kill(os.getpid(), signum)
        raise
    for signum, frame in pending:
        handler(signum, frame)
    return process


def run(command: list[str], timeout_seconds: int) -> int:
    started = time.monotonic()
    process = _start_with_signal_cleanup(command)
    try:
        return process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        elapsed = round(time.monotonic() - started, 1)
        # TERM first, then escalate, exactly as `timeout --signal=TERM
        # --kill-after` did: the runner needs the signal to report the failure and
        # to run its own cleanup, and only a command that ignores TERM gets KILL.
        print(f"run_with_timeout.py: command exceeded {timeout_seconds}s "
              f"(elapsed {elapsed}s); terminating it", file=sys.stderr, flush=True)
        _signal_group(process, signal.SIGTERM)
        grace = _grace_seconds()
        if os.name == "nt":
            # No graceful group signal exists, and `taskkill /T` needs a live root,
            # so the tree is ended now rather than after a grace that could let the
            # root exit.
            print(f"run_with_timeout.py: terminating the process tree",
                  file=sys.stderr, flush=True)
            _terminate_windows_tree_now(process)
        else:
            # The grace belongs to the GROUP: a worker may still be flushing results
            # or running its own TERM handler after the leader has already exited.
            _wait_for_group(process, grace)
            if _group_is_alive(process):
                print(f"run_with_timeout.py: the process group was still alive after "
                      f"{grace}s; killing it", file=sys.stderr, flush=True)
            _kill_tree(process)
        try:
            process.wait(timeout=60)
        except subprocess.TimeoutExpired:
            pass
        return TIMEOUT_EXIT_CODE


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("seconds", type=int,
                        help="deadline in seconds; must be positive")
    parser.add_argument("command", nargs=argparse.REMAINDER,
                        help="the command to run (a leading `--` is dropped)")
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        print("run_with_timeout.py: no command given", file=sys.stderr)
        return 2
    if args.seconds <= 0:
        print("run_with_timeout.py: the deadline must be positive", file=sys.stderr)
        return 2
    return run(command, args.seconds)


if __name__ == "__main__":
    sys.exit(main())
