#!/usr/bin/env python3
"""Prepare unmodified, bounded official Cangjie source subsets, never an SDK tree.

Default operation is offline. --download explicitly fetches immutable source
files into --cache. Output projects are documentation inputs, not buildable std
or stdx distributions; no declaration stubs or inventory entries are fabricated.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import os
import shutil
import sys
import tempfile
import urllib.error

from prepare_official_inventory import InventoryError, atomic_write, bounded_read, fetch_source, require

PINNED = {
    "std": {
        "repository": "cangjielanguage/cangjie_runtime",
        "revision": "c844ec7556f9ab624e6a052c550444d695c44f2e",
        "files": [
            ("stdlib/libs/std/collection/array_deque.cj", "array_deque.cj", "src/collection/array_deque.cj",
             "3c6b754a5de5bb61678265124584bd16bb7414613db0c939937ab0c2228f1348"),
            ("LICENSE", "runtime-LICENSE", "LICENSE",
             "1f6a5f318d4607c71c758cd4b2e62eb7d0943a12802a6797be66d7494ccabd6d"),
        ],
    },
    "stdx": {
        "repository": "cangjielanguage/cangjie_stdx",
        "revision": "f74bb5953547e51edff8904ae3db75ad47f17f06",
        "files": [
            ("src/stdx/encoding/json/json_object.cj", "json_object.cj", "src/encoding/json/json_object.cj",
             "41d9de5923696f575e08ce75e71c023424ba7b1b793eeffeff1461be23134584"),
            ("src/stdx/encoding/json/json_value.cj", "json_value.cj", "src/encoding/json/json_value.cj",
             "87d8fb0674a24b9b04bc9789970dd3049ed7d43b50d3e933f26fe988d563b9b6"),
            ("LICENSE", "stdx-LICENSE", "LICENSE",
             "c6b19ceadc94d277930cd8a91ea324c73f322e22561a58457e92962b1ffb110e"),
        ],
    },
}
MAX_FILE_BYTES = 1024 * 1024


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def source_uri(spec: dict, path: str) -> str:
    return "https://raw.githubusercontent.com/" + spec["repository"] + "/" + spec["revision"] + "/" + path


def checked_files(cache: Path, *, download: bool) -> tuple[list, dict]:
    require(not cache.is_symlink() and not any(p.is_symlink() for p in cache.parents), "symlink cache forbidden")
    prepared = []
    provenance = {"schemaVersion": "cjdoc.upstream-source-subset/1", "libraries": [],
                  "scope": "three unmodified source files; not complete libraries; no installed-SDK source claim",
                  "sdkMapping": "none", "apiVersion": "", "inventoryProducer": "cjdoc generate, not this prepare script"}
    for library, spec in PINNED.items():
        facts = []
        for upstream, name, destination, expected in spec["files"]:
            uri = source_uri(spec, upstream)
            cached = cache / name
            require(not cached.is_symlink(), "symlink cached source forbidden")
            data = fetch_source(uri) if download else bounded_read(cached, MAX_FILE_BYTES)
            require(len(data) <= MAX_FILE_BYTES and sha(data) == expected, "pinned upstream source/license digest mismatch")
            prepared.append((library, cached, destination, data))
            facts.append({"upstreamPath": upstream, "sourceUri": uri, "path": destination,
                          "sha256": expected, "bytes": len(data), "transformation": "none"})
        provenance["libraries"].append({"library": library, "repository": "https://github.com/" + spec["repository"],
                                        "sourceRevision": spec["revision"], "license": "Apache-2.0 with Runtime Library Exception",
                                        "files": facts})
    return prepared, provenance


def prepare(cache: Path, output: Path, *, download: bool = False) -> dict:
    require(not output.exists() and not output.is_symlink(), "output must be a new private directory")
    require(not any(p.is_symlink() for p in output.parents), "symlink output parent forbidden")
    files, provenance = checked_files(cache, download=download)
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".source-subset-", dir=output.parent))
    try:
        for library, _, destination, data in files:
            path = stage / library / destination
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        for library in PINNED:
            # A documentation wrapper only. Deliberately no package version: an
            # invented wrapper version must not become the upstream API version.
            (stage / library / "cjpm.toml").write_text(
                '[package]\nname = "' + library + '"\noutput-type = "static"\n', encoding="utf-8")
        (stage / "source-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
        if download:
            for _, cached, _, data in files:
                atomic_write(cached, data)
        os.rename(stage, output)
    except BaseException:
        shutil.rmtree(stage)
        raise
    return provenance


def verify_prepared(root: Path) -> dict:
    """Check source project input exactly; never trust hand-written type entries."""
    value = json.loads(bounded_read(root / "source-provenance.json", MAX_FILE_BYTES))
    require(value.get("schemaVersion") == "cjdoc.upstream-source-subset/1", "unexpected source provenance schema")
    require(not root.is_symlink() and not any(p.is_symlink() for p in root.parents), "symlink source root forbidden")
    for library, spec in PINNED.items():
        expected_paths = {destination for _, _, destination, _ in spec["files"]} | {"cjpm.toml"}
        actual = {p.relative_to(root / library).as_posix() for p in (root / library).rglob("*")
                  if p.is_file() and "target" not in p.relative_to(root / library).parts}
        require(actual == expected_paths and not any(p.is_symlink() for p in (root / library).rglob("*")), "unreviewed/missing/symlink source input")
        wrapper = '[package]\nname = "' + library + '"\noutput-type = "static"\n'
        require(bounded_read(root / library / "cjpm.toml", MAX_FILE_BYTES) == wrapper.encode("utf-8"), "documentation wrapper changed")
        facts = [item for item in value.get("libraries", []) if item.get("library") == library]
        require(len(facts) == 1 and facts[0].get("sourceRevision") == spec["revision"]
                and facts[0].get("repository") == "https://github.com/" + spec["repository"], "source provenance identity changed")
        for _, _, destination, expected in spec["files"]:
            require(sha(bounded_read(root / library / destination, MAX_FILE_BYTES)) == expected, "prepared source/license changed")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()
    try:
        prepare(args.cache.absolute(), args.output.absolute(), download=args.download)
    except (InventoryError, OSError, urllib.error.URLError) as error:
        print("source snapshot preparation failed: " + (str(error) if isinstance(error, InventoryError) else type(error).__name__), file=sys.stderr)
        return 2
    print("prepared 3 unmodified Cangjie source files in 2 documentation-only projects; no SDK mapping")
    return 0


if __name__ == "__main__":
    sys.exit(main())
