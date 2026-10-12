#!/usr/bin/env python3
"""Apply the STS build override and record what was applied.

Invoked by `scripts/with_sts_o1_cjpm.sh` for the duration of one wrapped
invocation, then undone by the wrapper's trap. Keeping the rewrite in a real script
rather than an embedded heredoc lets CI-08.3 run this same program instead of
pattern-matching the wrapper's text.

The receipt is written from the rewritten text, and the rewrite is asserted to have
produced the required option. A definition that stopped changing anything would
otherwise still be reported as applied, and the uniformity voucher would be false.

Usage: apply_sts_override.py MANIFEST BACKUP_DIR --receipt FILE [--manifest-path PATH]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sts_compile_override import OPTION, applied_option, apply_to, manifest_package

sys.dont_write_bytecode = True

RECEIPT_SCHEMA = "cjdoc.sts-override-receipt/1"


def patch(manifests: list[Path], backup_dir: Path) -> list[dict[str, str]]:
    """Rewrite each manifest, record the originals, and report what was applied."""
    updates = []
    applied = []
    for manifest in manifests:
        contents = manifest.read_text(encoding="utf-8")
        # The package name is read from the manifest: the provider fixture's
        # directory and package names differ, and a caller-supplied name could point
        # the rewrite at a manifest the release does not build.
        package = manifest_package(contents)
        rewritten = apply_to(contents)
        option = applied_option(rewritten)
        if option != OPTION:
            raise SystemExit(
                f"rewriting {manifest} produced override-compile-option={option!r}, not "
                f"the required {OPTION!r}; the build would not use the pinned option")
        updates.append((manifest, rewritten))
        applied.append({"package": package, "option": option})
    backup_dir.mkdir(parents=True, exist_ok=True)
    paths_file = backup_dir / "manifest-paths"
    for index, (manifest, _) in enumerate(updates):
        shutil.copy2(manifest, backup_dir / f"{index}.toml")
        with paths_file.open("ab") as stream:
            stream.write(str(manifest).encode("utf-8") + b"\0")
    for manifest, contents in updates:
        manifest.write_text(contents, encoding="utf-8")
    return applied


def write_receipt(path: Path, applied: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(json.dumps({
        "schemaVersion": RECEIPT_SCHEMA,
        "option": OPTION,
        "applied": applied,
    }, ensure_ascii=False, sort_keys=True), encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("manifest", type=Path)
    parser.add_argument("backup_dir", type=Path)
    parser.add_argument("--manifest-path", type=Path)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    manifests = [args.manifest]
    if args.manifest_path is not None:
        manifests.append(args.manifest_path)
    write_receipt(args.receipt, patch(manifests, args.backup_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
