#!/usr/bin/env python3
"""Compute the exact cache identity for Cangjie product build artifacts.

The cache covers dependency sources plus the root target/release tree and its
build-script cache, not a prebuilt executable selected by acceptance gates.
`cjpm build -i` remains authoritative for deciding which restored packages need
recompilation.
"""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True

CACHE_SCHEMA = "cjdoc.cjpm-product-cache/4"
PATH_DEPENDENCIES = (Path("vendor/yjson_algorithms"), Path("tools/chir-protocol"))
CACHE_MANIFESTS = (Path("cjpm.toml"), Path("cjpm.lock"),
                   Path("tools/chir-worker/cjpm.toml"),
                   Path("tools/chir-worker/cjpm.lock"),
                   Path("scripts/check.sh"),
                   Path("scripts/sts_compile_override.py"),
                   Path("scripts/apply_sts_override.py"),
                   Path("scripts/with_sts_cjpm.sh"),
                   Path("scripts/dependency_cache_key.py"))
CACHE_PATHS = ("~/.cjpm/git", "target/release", "build-script-cache/release")

from sts_compile_override import OPTION as PRODUCT_OPTIONS  # noqa: E402


def sha256_bytes(chunks: list[bytes]) -> str:
    digest = hashlib.sha256()
    for chunk in chunks:
        digest.update(chunk)
    return digest.hexdigest()


def source_hash(repo: Path) -> str:
    """Hash lock/config and path dependency bytes with unambiguous framing."""
    files = [repo / relative for relative in CACHE_MANIFESTS]
    for relative in PATH_DEPENDENCIES:
        root = repo / relative
        if not root.is_dir():
            raise SystemExit(f"dependency cache: missing path dependency {relative}")
        for path in root.rglob("*"):
            if path.is_symlink():
                raise SystemExit(f"dependency cache: symlink in path dependency {path.relative_to(repo)}")
            if path.is_file():
                files.append(path)
    chunks: list[bytes] = []
    for path in sorted(files, key=lambda item: item.relative_to(repo).as_posix()):
        if not path.is_file():
            raise SystemExit(f"dependency cache: required input is missing: {path.relative_to(repo)}")
        relative = path.relative_to(repo).as_posix().encode("utf-8")
        contents = path.read_bytes()
        chunks.extend((len(relative).to_bytes(8, "big"), relative,
                       len(contents).to_bytes(8, "big"), contents))
    return sha256_bytes(chunks)


def product_source_hash(repo: Path) -> str:
    """Hash root package sources; changed trees may restore an older prefix."""
    root = repo / "src"
    if not root.is_dir():
        raise SystemExit("dependency cache: missing product source directory src")
    files: list[Path] = []
    for path in root.rglob("*"):
        if path.is_symlink():
            raise SystemExit(f"dependency cache: symlink in product source tree {path.relative_to(repo)}")
        if path.is_file() and path.suffix == ".cj":
            files.append(path)
    chunks: list[bytes] = []
    for path in sorted(files, key=lambda item: item.relative_to(repo).as_posix()):
        relative = path.relative_to(repo).as_posix().encode("utf-8")
        contents = path.read_bytes()
        chunks.extend((len(relative).to_bytes(8, "big"), relative,
                       len(contents).to_bytes(8, "big"), contents))
    return sha256_bytes(chunks)


def compiler_target(value: str | None) -> str:
    if value:
        return value
    output = subprocess.run(["cjc", "-v"], check=True, capture_output=True, text=True).stdout
    match = re.search(r"^Target:\s*(\S+)$", output, re.MULTILINE)
    if match is None:
        raise SystemExit("dependency cache: cjc -v has no target")
    return match.group(1)


def required(value: str | None, name: str) -> str:
    if not value:
        raise SystemExit(f"dependency cache: missing {name}")
    return value


def cache_identity(repo: Path, *, platform: str | None = None, target: str | None = None,
                   compiler_fingerprint: str | None = None,
                   stdx_digest: str | None = None,
                   sdk_version: str | None = None,
                   cjpm_version: str | None = None,
                   options: str = PRODUCT_OPTIONS) -> tuple[str, str]:
    platform_value = required(platform or os.environ.get("CJDOC_CACHE_PLATFORM"),
                              "runner platform")
    target_value = compiler_target(target or os.environ.get("CJDOC_TOOLCHAIN_TARGET"))
    fingerprint = required(compiler_fingerprint or os.environ.get("CJDOC_TOOLCHAIN_FINGERPRINT"),
                           "compiler fingerprint")
    stdx = required(stdx_digest or os.environ.get("CJDOC_STDX_DIGEST"), "stdx digest")
    sdk = required(sdk_version or os.environ.get("CJDOC_TOOLCHAIN_VERSION")
                   or os.environ.get("CANGJIE_SDK_VERSION"), "SDK version")
    if cjpm_version is None:
        cjpm_version = subprocess.run(
            ["cjpm", "-v"], check=True, capture_output=True, text=True).stdout.strip()
    cjpm = required(cjpm_version, "cjpm version")
    dependency_identity = sha256_bytes([
        source_hash(repo).encode("ascii"), b"\0", options.encode("utf-8"), b"\0",
        platform_value.encode("utf-8"), b"\0", sdk.encode("utf-8"), b"\0",
        cjpm.encode("utf-8"), b"\0", target_value.encode("utf-8"), b"\0",
        fingerprint.encode("ascii"), b"\0", stdx.encode("ascii"), b"\0",
        b"static-dependencies;product-executable;incremental-v1",
    ])
    prefix = f"{CACHE_SCHEMA}-{platform_value}-{target_value}-{dependency_identity}-"
    return prefix, prefix + product_source_hash(repo)


def cache_key(repo: Path, **kwargs: str) -> str:
    """Return the exact checkout-specific cache key."""
    return cache_identity(repo, **kwargs)[1]


def github_outputs(prefix: str, key: str) -> str:
    paths = "\n".join(CACHE_PATHS)
    return (f"restore-prefix={prefix}\nkey={key}\n"
            f"paths<<CJDOC_CACHE_PATHS\n{paths}\nCJDOC_CACHE_PATHS\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path("."))
    parser.add_argument("--platform")
    parser.add_argument("--target")
    parser.add_argument("--compiler-fingerprint")
    parser.add_argument("--stdx-digest")
    parser.add_argument("--sdk-version")
    parser.add_argument("--cjpm-version")
    parser.add_argument("--github-output", type=Path,
                        help="append key and cache paths in GitHub Actions output format")
    args = parser.parse_args()
    prefix, key = cache_identity(
        args.repo.resolve(), platform=args.platform, target=args.target,
        compiler_fingerprint=args.compiler_fingerprint,
        stdx_digest=args.stdx_digest, sdk_version=args.sdk_version,
        cjpm_version=args.cjpm_version)
    output = github_outputs(prefix, key)
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8", newline="\n") as stream:
            stream.write(output)
    sys.stdout.write(output)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
