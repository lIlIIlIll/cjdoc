from __future__ import annotations

import hashlib
import subprocess
import tempfile
from pathlib import Path

try:
    from .repository_input_contracts import (
        COMMIT,
        CURRENT_GOLDEN_VERSION,
        GOLDEN_NAMES,
        LEGACY_GOLDEN_VERSIONS,
        LEGACY_MIGRATION_RECEIPT_SHA256,
        SHA256,
    )
    from .repository_input_files import sha256
    from .safe_output_root import lexical_absolute, safe_regular_file
    from .strict_json import strict_dumps, strict_load, strict_loads
except ImportError:  # Direct module execution.
    from repository_input_contracts import (
        COMMIT,
        CURRENT_GOLDEN_VERSION,
        GOLDEN_NAMES,
        LEGACY_GOLDEN_VERSIONS,
        LEGACY_MIGRATION_RECEIPT_SHA256,
        SHA256,
    )
    from repository_input_files import sha256
    from safe_output_root import lexical_absolute, safe_regular_file
    from strict_json import strict_dumps, strict_load, strict_loads

def resolve_binary(value: Path) -> Path:
    candidate = lexical_absolute(value)
    for executable in (candidate, Path(f"{candidate}.exe")):
        try:
            executable.lstat()
        except FileNotFoundError:
            continue
        return safe_regular_file(executable, description="legacy migration binary")
    raise ValueError(f"legacy migration binary does not exist: {candidate}")


def run_doc_ir_render(binary: Path, source: Path) -> bytes:
    try:
        result = subprocess.run(
            [str(binary), "render", "--input", str(source), "--format", "json", "--stdout"],
            capture_output=True, check=False, timeout=30,
        )
    except subprocess.TimeoutExpired as error:
        raise ValueError(f"Doc IR render validation timed out: {source}") from error
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).decode("utf-8", "replace").strip()
        raise ValueError(f"Doc IR render validation failed for {source}: {detail}")
    try:
        value = strict_loads(result.stdout, description=f"migration output for {source}")
    except ValueError as error:
        raise ValueError(f"Doc IR render emitted invalid JSON for {source}: {error}") from error
    if not isinstance(value, dict) or value.get("schemaVersion") != "cjdoc.doc-ir/8":
        raise ValueError(f"Doc IR render did not emit Doc IR v8: {source}")
    return result.stdout


def run_legacy_render(binary: Path, source: Path) -> bytes:
    return run_doc_ir_render(binary, source)


def verify_current_goldens(repo: Path, binary_value: Path) -> list[str]:
    """Exercise the repository's real yjson-backed Doc IR decoder on every v8 golden."""
    binary = resolve_binary(binary_value)
    verified: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cjdoc-current-golden-") as temporary:
        work = Path(temporary)
        for name in GOLDEN_NAMES:
            relative = f"tests/fixtures/golden-v8/{name}.docs.json"
            source = repo / relative
            output = run_doc_ir_render(binary, source)
            if output != source.read_bytes():
                raise ValueError(f"v8 golden is not an exact strict round-trip: {relative}")
            verified.append(relative)

        corrupted = strict_load(
            repo / "tests/fixtures/golden-v8/basic.docs.json",
            description="v8 corruption regression source",
        )
        if not isinstance(corrupted, dict) or "generator" not in corrupted:
            raise ValueError("v8 corruption regression source is malformed")
        del corrupted["generator"]
        corrupt_path = work / "missing-generator.docs.json"
        corrupt_path.write_text(
            strict_dumps(corrupted, ensure_ascii=False, sort_keys=True) + "\n",
            encoding="utf-8", newline="\n",
        )
        try:
            result = subprocess.run(
                [str(binary), "render", "--input", str(corrupt_path),
                 "--format", "json", "--stdout"],
                capture_output=True, check=False, timeout=30,
            )
        except subprocess.TimeoutExpired as error:
            raise ValueError("corrupt v8 Doc IR rejection timed out") from error
        if result.returncode == 0:
            raise ValueError("yjson-backed Doc IR validation accepted a missing required field")
    return verified


def semantic_digest(value: object) -> str:
    canonical = strict_dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def verify_legacy_receipts(repo: Path) -> dict[str, dict[str, dict[str, object]]]:
    path = repo / "tests/fixtures/legacy-migration-v8.json"
    if sha256(path) != LEGACY_MIGRATION_RECEIPT_SHA256:
        raise ValueError("legacy migration receipt manifest is not byte-frozen")
    value = strict_load(path, description="legacy migration receipts")
    if not isinstance(value, dict) or set(value) != {
        "schemaVersion", "targetSchemaVersion", "migrations"
    } or value.get("schemaVersion") != "cjdoc.legacy-migration-receipts/1" or \
            value.get("targetSchemaVersion") != "cjdoc.doc-ir/8":
        raise ValueError("legacy migration receipt manifest schema is invalid")
    migrations = value.get("migrations")
    if not isinstance(migrations, dict) or set(migrations) != {"6", "7"}:
        raise ValueError("legacy migration receipt versions are incomplete")
    expected_names = set(GOLDEN_NAMES)
    for version in LEGACY_GOLDEN_VERSIONS:
        entries = migrations.get(str(version))
        if not isinstance(entries, dict) or set(entries) != expected_names:
            raise ValueError(f"v{version} legacy migration receipts are incomplete")
        for name, receipt in entries.items():
            if not isinstance(receipt, dict) or set(receipt) != {
                "sourceSha256", "v8SemanticSha256", "declarations", "modules",
                "diagnostics", "unsupportedDeclarations",
            }:
                raise ValueError(f"invalid v{version} migration receipt: {name}")
            if any(not isinstance(receipt[field], int) or receipt[field] < 0 for field in (
                "declarations", "modules", "diagnostics", "unsupportedDeclarations"
            )) or any(not isinstance(receipt[field], str) or not SHA256.fullmatch(receipt[field])
                      for field in ("sourceSha256", "v8SemanticSha256")):
                raise ValueError(f"invalid v{version} migration receipt values: {name}")
            source = repo / f"tests/fixtures/golden-v{version}/{name}.docs.json"
            if sha256(source) != receipt["sourceSha256"]:
                raise ValueError(f"v{version} legacy input is not byte-frozen: {name}")
    return migrations


def verify_legacy_migrations(repo: Path, binary_value: Path) -> list[str]:
    binary = resolve_binary(binary_value)
    receipts = verify_legacy_receipts(repo)
    verified: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cjdoc-legacy-migration-") as temporary:
        migrated = Path(temporary) / "migrated.docs.json"
        for version in LEGACY_GOLDEN_VERSIONS:
            for name in GOLDEN_NAMES:
                relative = f"tests/fixtures/golden-v{version}/{name}.docs.json"
                output = run_legacy_render(binary, repo / relative)
                migrated_value = strict_loads(
                    output, description=f"migrated Doc IR for {relative}"
                )
                receipt = receipts[str(version)][name]
                actual = {
                    "v8SemanticSha256": semantic_digest(migrated_value),
                    "declarations": len(migrated_value.get("declarations", [])),
                    "modules": len(migrated_value.get("modules", [])),
                    "diagnostics": len(migrated_value.get("diagnostics", [])),
                    "unsupportedDeclarations": len(
                        migrated_value.get("unsupportedDeclarations", [])
                    ),
                }
                expected = {key: receipt[key] for key in actual}
                if actual != expected:
                    raise ValueError(f"legacy migration semantic receipt mismatch: {relative}")
                migrated.write_bytes(output)
                roundtrip = run_legacy_render(binary, migrated)
                if roundtrip != output:
                    raise ValueError(f"legacy migration is not a stable v8 round-trip: {relative}")
                verified.append(relative)
    return verified

