from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

try:
    from .repository_input_contracts import CURRENT_GOLDEN_VERSION, GOLDEN_NAMES
    from .safe_output_root import lexical_absolute, safe_regular_file
    from .strict_json import strict_dumps, strict_load, strict_loads
except ImportError:  # Direct module execution.
    from repository_input_contracts import CURRENT_GOLDEN_VERSION, GOLDEN_NAMES
    from safe_output_root import lexical_absolute, safe_regular_file
    from strict_json import strict_dumps, strict_load, strict_loads

def resolve_binary(value: Path) -> Path:
    candidate = lexical_absolute(value)
    for executable in (candidate, Path(f"{candidate}.exe")):
        try:
            executable.lstat()
        except FileNotFoundError:
            continue
        return safe_regular_file(executable, description="Doc IR validation binary")
    raise ValueError(f"Doc IR validation binary does not exist: {candidate}")


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
        value = strict_loads(result.stdout, description=f"Doc IR render output for {source}")
    except ValueError as error:
        raise ValueError(f"Doc IR render emitted invalid JSON for {source}: {error}") from error
    if not isinstance(value, dict) or value.get("schemaVersion") != f"cjdoc.doc-ir/{CURRENT_GOLDEN_VERSION}":
        raise ValueError(f"Doc IR render did not emit current Doc IR: {source}")
    return result.stdout


def verify_current_goldens(repo: Path, binary_value: Path) -> list[str]:
    """Exercise the repository's real yjson-backed Doc IR decoder on every current golden."""
    binary = resolve_binary(binary_value)
    verified: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cjdoc-current-golden-") as temporary:
        work = Path(temporary)
        for name in GOLDEN_NAMES:
            relative = f"tests/fixtures/golden-v{CURRENT_GOLDEN_VERSION}/{name}.docs.json"
            source = repo / relative
            output = run_doc_ir_render(binary, source)
            if output != source.read_bytes():
                raise ValueError(f"current golden is not an exact strict round-trip: {relative}")
            verified.append(relative)

        corrupted = strict_load(
            repo / f"tests/fixtures/golden-v{CURRENT_GOLDEN_VERSION}/basic.docs.json",
            description="current corruption regression source",
        )
        if not isinstance(corrupted, dict) or "generator" not in corrupted:
            raise ValueError("current corruption regression source is malformed")
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
            raise ValueError("corrupt current Doc IR rejection timed out") from error
        if result.returncode == 0:
            raise ValueError("yjson-backed Doc IR validation accepted a missing required field")
    return verified
