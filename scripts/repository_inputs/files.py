from __future__ import annotations

import hashlib
from pathlib import Path, PurePosixPath
import tomllib
from typing import Any

from .contracts import CURRENT_GOLDEN_VERSION, GOLDEN_NAMES, SCHEMA_NAMES
from .schema import validate_schema_document

if __package__ == "repository_inputs":  # Imported by a direct script entry point.
    from release_package_contracts import API_COMMENT_SKILL_FILES
    from safe_output_root import lexical_absolute, verify_directory_chain
    from showcase_inputs import source_inputs
    from strict_json import strict_load
else:
    from ..release_package_contracts import API_COMMENT_SKILL_FILES
    from ..safe_output_root import lexical_absolute, verify_directory_chain
    from ..showcase_inputs import source_inputs
    from ..strict_json import strict_load


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_relative(value: object, description: str) -> PurePosixPath:
    if not isinstance(value, str) or not value or "\\" in value:
        raise ValueError(f"{description} must be a non-empty POSIX relative path")
    path = PurePosixPath(value)
    if value in (".", "..") or path.as_posix() != value or path.is_absolute() or \
            any(part in ("", ".", "..") for part in path.parts):
        raise ValueError(f"{description} is unsafe: {value!r}")
    return path


def read_toml(path: Path) -> dict[str, Any]:
    value = tomllib.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"TOML root is not a table: {path}")
    return value


def required_repository_paths() -> tuple[str, ...]:
    paths = [
        "README.md",
        "LICENSE",
        "cjpm.toml",
        "cjpm.lock",
        "THIRD_PARTY_NOTICES.md",
        "third_party/licenses/markdown-LICENSE",
        "vendor/yjson_algorithms/LICENSE",
        "vendor/yjson_algorithms/UPSTREAM.md",
        "vendor/yjson_algorithms/cjpm.toml",
        "vendor/yjson_algorithms/vendor-manifest.toml",
        "cjdoc.toml",
        "site/showcase-baseline.json",
        "scripts/requirements-showcase.txt",
        *API_COMMENT_SKILL_FILES,
    ]
    paths.extend(source_inputs())
    paths.extend(f"docs/schema/{name}.schema.json" for name in SCHEMA_NAMES)
    paths.extend(
        f"tests/fixtures/golden-v{CURRENT_GOLDEN_VERSION}/{name}.docs.json"
        for name in GOLDEN_NAMES
    )
    return tuple(paths)


def verify_golden_set(repo: Path, version: int) -> None:
    directory = repo / f"tests/fixtures/golden-v{version}"
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"v{version} golden directory must be a regular repository directory")
    for candidate in sorted(directory.parent.glob("golden-v[0-9]*")):
        suffix = candidate.name.removeprefix("golden-v")
        if candidate != directory and suffix.isascii() and suffix.isdecimal():
            raise ValueError(f"obsolete v{suffix} golden inventory must not be retained")
    expected = {f"{name}.docs.json" for name in GOLDEN_NAMES}
    actual = {path.name for path in directory.glob("*.docs.json")}
    missing = sorted(expected - actual)
    unexpected = sorted(actual - expected)
    if missing or unexpected:
        raise ValueError(
            f"v{version} golden set mismatch: missing=" + ",".join(missing) +
            " unexpected=" + ",".join(unexpected)
        )
    expected_version = f"cjdoc.doc-ir/{version}"
    for name in sorted(expected):
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"v{version} golden must be a regular file: {name}")
        value = strict_load(path, description=f"v{version} golden {name}")
        if not isinstance(value, dict) or value.get("schemaVersion") != expected_version:
            raise ValueError(f"v{version} golden has the wrong schemaVersion: {name}")


def load_frozen_doc_ir_definitions(directory: Path) -> dict:
    # Artifact schemas embed the current Doc IR declarations; load that
    # model once and reject forks in every consumer schema.
    model = strict_load(directory / "doc-ir-v20.schema.json", description="doc-ir-v20 schema")
    if not isinstance(model, dict) or not isinstance(model.get("$defs"), dict):
        raise ValueError("doc-ir-v20 schema definitions are missing")
    return model["$defs"]


def verify_schema_set(repo: Path) -> None:
    directory = lexical_absolute(repo / "docs/schema")
    verified = verify_directory_chain(directory)
    if verified != directory:
        raise ValueError("published schema directory identity changed during verification")
    if not directory.is_dir():
        raise ValueError("published schema directory must be a regular repository directory")
    expected = {f"{name}.schema.json" for name in SCHEMA_NAMES}
    actual = {path.name for path in directory.glob("*.schema.json")}
    missing = sorted(expected - actual)
    unexpected = sorted(actual - expected)
    if missing or unexpected:
        raise ValueError(
            "published schema set mismatch: missing=" + ",".join(missing) +
            " unexpected=" + ",".join(unexpected)
        )
    frozen_definitions = load_frozen_doc_ir_definitions(directory)
    for name in SCHEMA_NAMES:
        path = directory / f"{name}.schema.json"
        value = strict_load(path, description=f"{name} schema")
        validate_schema_document(name, value, frozen_definitions)
