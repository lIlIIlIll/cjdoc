#!/usr/bin/env python3
"""Small cross-platform probes used by cjdoc's shell acceptance gates."""

from __future__ import annotations

import argparse
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("monotonic-ns")
    inode = subcommands.add_parser("inode")
    inode.add_argument("path", type=Path)
    args = parser.parse_args()

    if args.command == "monotonic-ns":
        print(time.monotonic_ns())
    else:
        print(args.path.stat().st_ino)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
