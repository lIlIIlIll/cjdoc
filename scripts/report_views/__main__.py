"""Render native report views in an assembled cjdoc HTML directory."""
import argparse
from pathlib import Path

from . import pages, reports


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--locale", required=True)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--current", type=Path)
    parser.add_argument("--diff", type=Path)
    args = parser.parse_args()
    reports.publish(args.root, args.revision, args.version, args.locale,
                    baseline=args.baseline, current=args.current, diff_path=args.diff)
    pages.publish(args.root)
    reports.verify(args.root, args.revision)


if __name__ == "__main__":
    main()
