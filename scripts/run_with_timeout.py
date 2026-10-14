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
# same grace `timeout --kill-after=60` provided.
GRACE_SECONDS = 60


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
    if signum == signal.SIGTERM and process.poll() is None:
        try:
            process.terminate()
        except OSError:
            pass


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
    subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if process.poll() is None:
        try:
            process.kill()
        except OSError:
            pass


def _install_signal_cleanup(process: subprocess.Popen) -> dict:
    """Kill the child's group if the wrapper itself is interrupted.

    `check.sh` and its parent jobs send SIGTERM on cancellation. Without this the
    wrapper exits while the command keeps running in its own session, so `cjpm test`
    survives as an orphan and continues mutating fixture and build outputs under the
    next run.
    """
    previous: dict = {}

    def handler(signum, frame) -> None:
        _signal_group(process, signal.SIGTERM)
        try:
            process.wait(timeout=GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            pass
        # Same rule as the expiry path: the group is killed even when the leader
        # obeyed TERM, because a worker in its session may not have.
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

    for signum in (signal.SIGTERM, signal.SIGINT):
        try:
            previous[signum] = signal.signal(signum, handler)
        except (ValueError, OSError):
            pass
    return previous


def run(command: list[str], timeout_seconds: int) -> int:
    started = time.monotonic()
    process = subprocess.Popen(
        command,
        start_new_session=os.name == "posix",
        creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        if os.name == "nt" else 0,
    )
    _install_signal_cleanup(process)
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
        leader_exited = True
        try:
            process.wait(timeout=GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            leader_exited = False
        # The group is killed even when the LEADER obeyed TERM: a worker in the same
        # session can ignore it, and the leader's exit would otherwise end this
        # function while that worker keeps running and mutating shared outputs.
        # Killing an already-empty group is harmless (ESRCH).
        if not leader_exited:
            print(f"run_with_timeout.py: command ignored SIGTERM after "
                  f"{GRACE_SECONDS}s; killing the process group", file=sys.stderr,
                  flush=True)
        _kill_tree(process)
        if leader_exited:
            print("run_with_timeout.py: terminating any remaining process group",
                  file=sys.stderr, flush=True)
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
