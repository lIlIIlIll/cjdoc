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


def run(command: list[str], timeout_seconds: int) -> int:
    started = time.monotonic()
    process = subprocess.Popen(
        command,
        start_new_session=os.name == "posix",
        creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        if os.name == "nt" else 0,
    )
    try:
        return process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        elapsed = round(time.monotonic() - started, 1)
        print(f"run_with_timeout.py: command exceeded {timeout_seconds}s "
              f"(elapsed {elapsed}s); terminating the process tree", file=sys.stderr,
              flush=True)
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
