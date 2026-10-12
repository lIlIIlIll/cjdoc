#!/usr/bin/env python3
"""Apply the STS build override to the manifests `cjpm` will read.

Invoked by `scripts/with_sts_o1_cjpm.sh` for the duration of one wrapped
invocation, then undone by the wrapper's trap. Keeping the rewrite in a real
script rather than an embedded heredoc lets CI-08.3 exercise this exact call path
instead of pattern-matching the wrapper's text.

Usage: apply_sts_override.py MANIFEST BACKUP_DIR [PATCH_FIXTURE_ENTRY]
  --manifest-path   extra manifest to patch (the provider fixture entry point)
  --root-package    package name expected in the root manifest
"""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sts_compile_override import apply_to

sys.dont_write_bytecode = True


def patch(manifests: list[tuple[Path, str]], backup_dir: Path) -> None:
    """Rewrite each manifest and record the originals for the caller's restore."""
    updates = [(manifest, apply_to(manifest.read_text(encoding="utf-8"), expected))
               for manifest, expected in manifests]
    backup_dir.mkdir(parents=True, exist_ok=True)
    paths_file = backup_dir / "manifest-paths"
    for index, (manifest, _) in enumerate(updates):
        shutil.copy2(manifest, backup_dir / f"{index}.toml")
        with paths_file.open("ab") as stream:
            stream.write(str(manifest).encode("utf-8") + b"\0")
    for manifest, contents in updates:
        manifest.write_text(contents, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("manifest", type=Path)
    parser.add_argument("backup_dir", type=Path)
    parser.add_argument("patch_fixture_entry", nargs="?", default="0")
    parser.add_argument("--manifest-path", type=Path, action="append", default=[])
    parser.add_argument("--root-package", default="cjdoc")
    args = parser.parse_args()
    manifests = [(args.manifest, args.root_package)]
    for extra in args.manifest_path:
        manifests.append((extra, extra.parent.name))
    patch(manifests, args.backup_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
