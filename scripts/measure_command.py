#!/usr/bin/env python3
"""Run one command and print portable wall-time / best-effort RSS evidence."""

from __future__ import annotations

import json
import platform
import subprocess
import sys
import time


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: measure_command.py <command> [args...]", file=sys.stderr)
        return 2

    started = time.perf_counter()
    result = subprocess.run(sys.argv[1:], check=False)
    elapsed_ms = round((time.perf_counter() - started) * 1000)

    peak_rss_kib = None
    try:
        import resource

        raw = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        peak_rss_kib = round(raw / 1024) if platform.system() == "Darwin" else raw
    except (ImportError, OSError):
        pass

    print(json.dumps({
        "elapsedMs": elapsed_ms,
        "exitCode": result.returncode,
        "peakRssKiB": peak_rss_kib,
    }, sort_keys=True))
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
