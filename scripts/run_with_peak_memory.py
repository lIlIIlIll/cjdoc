#!/usr/bin/env python3
"""Run one command and record child peak RSS without polling the process."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

try:
    import resource
except ImportError:  # Windows has no resource module.
    resource = None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("a command is required after --")
    completed = subprocess.run(command, check=False)
    if resource is None:
        peak = -1
    else:
        peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        # Linux reports KiB; macOS reports bytes.
        if sys.platform == "darwin":
            peak //= 1024
    args.output.write_text(f"{peak}\n", encoding="ascii")
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
