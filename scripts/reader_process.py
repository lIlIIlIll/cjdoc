"""Per-process, bounded measurements for the native reader benchmark."""
from __future__ import annotations

import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time


def measured_process(command: list[str], stdout: Path, stderr: Path,
                     timeout: float) -> dict:
    """Measure one process tree without confusing cumulative child RSS with its RSS."""
    if os.name != "posix" or not hasattr(os, "wait4"):
        raise ValueError("bounded native process-tree measurement requires POSIX wait4; unsupported is not PASS")
    expired = threading.Event()
    started = time.perf_counter()
    with stdout.open("wb") as output, stderr.open("wb") as errors:
        process = subprocess.Popen(command, stdout=output, stderr=errors,
                                   start_new_session=os.name == "posix")

        def kill_group() -> None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

        def terminate() -> None:
            if process.returncode is not None:
                return
            expired.set()
            kill_group()

        timer = threading.Timer(timeout, terminate)
        timer.daemon = True
        timer.start()
        try:
            _, status, usage = os.wait4(process.pid, 0)
            process.returncode = os.waitstatus_to_exitcode(status)
            resources = {
                "userCpuMs": usage.ru_utime * 1000,
                "systemCpuMs": usage.ru_stime * 1000,
                "peakRssBytes": int(usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024)),
                "measurement": "wait4-process-and-terminated-children",
                "rssSemantics": "maximum single-process RSS, not concurrent process-tree RSS",
            }
        except BaseException:
            terminate()
            process.wait()
            raise
        finally:
            timer.cancel()
            timer.join()
            # A completed parent does not imply its descendants have exited.
            # Do not leave an orphaned group running after cancelling its deadline.
            kill_group()
    return {"exitCode": process.returncode, "timedOut": expired.is_set(),
            "elapsedMs": (time.perf_counter() - started) * 1000, **resources}
