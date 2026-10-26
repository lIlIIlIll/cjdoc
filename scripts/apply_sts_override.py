#!/usr/bin/env python3
"""Apply the STS build override to the manifests `cjpm` will read.

Invoked by `scripts/with_sts_cjpm.sh` for the duration of one wrapped
invocation, then undone by the wrapper's trap. Keeping the rewrite in a real script
rather than an embedded heredoc lets CI-08.3 run this same call path instead of
pattern-matching the wrapper's text.

There is deliberately no "what I applied" output: the check reads the manifest the
real `cjpm` would read, so the patcher's own account could not add anything and
could only disagree with the thing that decides.

Usage: apply_sts_override.py MANIFEST BACKUP_DIR [--manifest-path PATH] [--command build|test|run]
"""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sts_compile_override import applied_option, apply_to, manifest_package, option_for

sys.dont_write_bytecode = True


def patch(manifests: list[Path], backup_dir: Path, command: str = "build") -> None:
    """Rewrite each manifest and record the originals for the caller's restore."""
    expected_option = option_for(command)
    updates = []
    for manifest in manifests:
        contents = manifest.read_text(encoding="utf-8")
        # The package name is read from the manifest: the provider fixture's
        # directory and package names differ, and a caller-supplied name could point
        # the rewrite at a manifest the release does not build.
        manifest_package(contents)
        rewritten = apply_to(contents, command)
        option = applied_option(rewritten, command)
        if option != expected_option:
            raise SystemExit(
                f"rewriting {manifest} produced override-compile-option={option!r}, not "
                f"the required {expected_option!r}; the build would not use the pinned option")
        updates.append((manifest, rewritten))
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
    parser.add_argument("--manifest-path", type=Path)
    parser.add_argument("--command", choices=("build", "test", "run"), default="build")
    args = parser.parse_args()
    manifests = [args.manifest]
    if args.manifest_path is not None:
        manifests.append(args.manifest_path)
    patch(manifests, args.backup_dir, args.command)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
