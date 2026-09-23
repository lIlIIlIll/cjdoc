#!/usr/bin/env python3
"""Run a command with the authenticated, matching static stdx sidecar."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Iterable


REQUIRED_STATIC_ARTIFACTS = (
    "stdx.syntax.cjo",
    "stdx.chir.cjo",
    "libstdx.syntax.a",
    "libstdx.syntaxFFI.a",
    "libstdx.chir.a",
)
REQUIRED_DYNAMIC_ARTIFACTS = (
    "stdx.syntax.cjo",
    "stdx.chir.cjo",
    "libstdx.syntax.so",
    "libstdx.chir.so",
)
VERSION_RE = re.compile(r"Cangjie Compiler:\s*([^\n]+)")
TARGET_RE = re.compile(r"Target:\s*([^\n]+)")


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"with_stdx.py: {message}")


def unique_paths(paths: Iterable[Path]) -> list[Path]:
    result: list[Path] = []
    seen: set[str] = set()
    for path in paths:
        try:
            normalized = path.expanduser().resolve(strict=True)
        except FileNotFoundError:
            continue
        key = normalized.as_posix()
        if key not in seen:
            seen.add(key)
            result.append(normalized)
    return result


def compiler_candidates() -> list[Path]:
    candidates: list[Path] = []
    for variable in ("CANGJIE_HOME", "CANGJIE_SDK_ROOT"):
        value = os.environ.get(variable)
        if not value:
            continue
        root = Path(value)
        candidates.extend((root / "bin" / "cjc", root / "cangjie" / "bin" / "cjc"))
    located = shutil.which("cjc")
    if located:
        candidates.append(Path(located))
    return unique_paths(candidates)


def compiler_info(cjc: Path) -> tuple[str, str]:
    try:
        completed = subprocess.run(
            [str(cjc), "-v"],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as error:
        fail(f"cannot query compiler version: {error}")
    output = f"{completed.stdout}\n{completed.stderr}"
    version = VERSION_RE.search(output)
    target = TARGET_RE.search(output)
    if version is None or target is None:
        fail("compiler version output is incomplete")
    return version.group(1).strip(), target.group(1).strip()


def compiler_bundle_root(cjc: Path) -> Path | None:
    resolved = cjc.resolve()
    if resolved.parent.name != "bin" or resolved.parent.parent.name != "cangjie":
        return None
    return resolved.parent.parent.parent


def stdx_candidates(cjc: Path, variant: str) -> list[Path]:
    candidates: list[Path] = []
    bundle = compiler_bundle_root(cjc)
    if bundle is not None:
        for target in sorted(bundle.glob("*_cjnative")):
            candidates.append(target / variant / "stdx")
            if variant == "static":
                candidates.append(target / "static-static-link-extern" / "stdx")
    configured = os.environ.get("CANGJIE_STDX_PATH")
    if configured:
        configured_path = Path(configured)
        if configured_path.name == "stdx":
            parent = configured_path.parent
            if parent.name == variant:
                candidates.append(parent / "stdx")
            candidates.append(parent.parent / variant / "stdx")
    return unique_paths(candidates)


def authenticate_stdx(path: Path, required_artifacts: tuple[str, ...]) -> tuple[str, list[Path]]:
    if path.name != "stdx" or not path.is_dir() or path.is_symlink():
        fail("stdx path must be a regular stdx directory")
    missing = [name for name in required_artifacts if not (path / name).is_file()]
    if missing:
        fail(f"stdx sidecar is missing required artifacts: {', '.join(missing)}")
    digest = hashlib.sha256()
    files: list[Path] = []
    for item in sorted(path.iterdir(), key=lambda candidate: candidate.name):
        if item.is_symlink():
            fail(f"stdx sidecar contains a symlink: {item.name}")
        if not item.is_file():
            continue
        if not (item.suffix in {".a", ".bc", ".cjo", ".so"} or item.name.startswith("lib")):
            continue
        files.append(item)
        digest.update(item.name.encode("utf-8"))
        digest.update(b"\0")
        with item.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        digest.update(b"\0")
    return digest.hexdigest(), files


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def static_link_options(path: Path, target: str) -> tuple[str, str]:
    candidates = [path / "libflatbuffers.a"]
    configured = os.environ.get("CANGJIE_FLATBUFFERS_LIB")
    if configured:
        candidates.insert(0, Path(configured))
    flatbuffers = next(
        (candidate.resolve() for candidate in candidates
         if candidate.is_file() and not candidate.is_symlink()),
        None,
    )
    options: list[str] = []
    dependency_digest = ""
    if flatbuffers is not None:
        options.append(str(flatbuffers))
        dependency_digest = file_digest(flatbuffers)
    if target.endswith("-linux-gnu"):
        options[0:0] = ["-lstdc++", "-lgcc_s"]
    return " ".join(options), dependency_digest


def split_command(argv: list[str]) -> tuple[list[str], list[str]]:
    try:
        marker = argv.index("--")
    except ValueError:
        fail("usage: with_stdx.py [--variant static|dynamic] [--print-env] -- command [args...]")
    return argv[:marker], argv[marker + 1 :]


def parse_options(options: list[str]) -> tuple[str, bool]:
    print_only = options.count("--print-env") == 1
    remaining = [option for option in options if option != "--print-env"]
    if options.count("--print-env") > 1:
        fail("--print-env may be specified once")
    if not remaining:
        return "static", print_only
    if len(remaining) == 1 and remaining[0].startswith("--variant="):
        variant = remaining[0].split("=", 1)[1]
    elif len(remaining) == 2 and remaining[0] == "--variant":
        variant = remaining[1]
    else:
        fail(f"unknown options: {' '.join(options)}")
    if variant not in {"static", "dynamic"}:
        fail("variant must be static or dynamic")
    return variant, print_only


def main(argv: list[str]) -> int:
    options, command = split_command(argv)
    variant, print_only = parse_options(options)
    if not command and not print_only:
        fail("missing command")

    cjc = next(iter(compiler_candidates()), None)
    if cjc is None:
        fail("cannot locate cjc from the configured SDK environment")
    version, target = compiler_info(cjc)
    required = REQUIRED_STATIC_ARTIFACTS if variant == "static" else REQUIRED_DYNAMIC_ARTIFACTS
    selected: Path | None = None
    selected_digest = ""
    for candidate in stdx_candidates(cjc, variant):
        try:
            digest, _ = authenticate_stdx(candidate, required)
        except SystemExit:
            continue
        selected = candidate
        selected_digest = digest
        break
    if selected is None:
        fail(f"no authenticated {variant} stdx sidecar matches the selected compiler")

    link_options = ""
    dependency_digest = ""
    if variant == "static":
        link_options, dependency_digest = static_link_options(selected, target)
    fingerprint = hashlib.sha256(
        f"{version}\0{target}\0{selected_digest}\0{dependency_digest}".encode("utf-8")
    ).hexdigest()
    environment = os.environ.copy()
    environment.update(
        {
            "CANGJIE_STDX_PATH": str(selected),
            "CJDOC_STDX_PATH": str(selected),
            "CJDOC_STDX_VARIANT": variant,
            "CJDOC_STDX_DIGEST": selected_digest,
            "CJDOC_STDX_LINK_OPTIONS": link_options,
            "CJDOC_STDX_DEPENDENCY_DIGEST": dependency_digest,
            "CJDOC_TOOLCHAIN_VERSION": version,
            "CJDOC_TOOLCHAIN_TARGET": target,
            "CJDOC_TOOLCHAIN_FINGERPRINT": fingerprint,
            "CJDOC_STDX_WRAPPED": "1",
        }
    )
    if print_only:
        for key in (
            "CANGJIE_STDX_PATH",
            "CJDOC_STDX_PATH",
            "CJDOC_STDX_VARIANT",
            "CJDOC_STDX_DIGEST",
            "CJDOC_STDX_LINK_OPTIONS",
            "CJDOC_STDX_DEPENDENCY_DIGEST",
            "CJDOC_TOOLCHAIN_VERSION",
            "CJDOC_TOOLCHAIN_TARGET",
            "CJDOC_TOOLCHAIN_FINGERPRINT",
        ):
            print(f"{key}={environment[key]}")
        return 0
    os.execvpe(command[0], command, environment)
    return 127


if __name__ == "__main__":
    main(sys.argv[1:])
