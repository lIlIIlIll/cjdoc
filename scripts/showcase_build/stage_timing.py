"""Optional phase timing for the showcase generator.

The showcase build is a long serial pipeline. Before any step is allowed to run
concurrently it must be measured, so this module records per-phase wall time
without changing behaviour: it never writes into the generated site, and it is a
no-op when no evidence destination is configured.

Evidence lands at ``$CJDOC_CI_EVIDENCE/showcase-stages.json`` (schema
``cjdoc.ci-stage/1`` through ``scripts/ci_stage.py`` when available) or at
``target/ci-evidence/showcase-stages.json`` when the repository is present.
"""

from __future__ import annotations

from contextlib import contextmanager
import json
import os
from pathlib import Path
import time

RECORDS: list[dict] = []


def _repository_root() -> Path | None:
    """Locate the enclosing repository, if this file still lives inside one."""
    candidate = Path(__file__).resolve()
    for parent in candidate.parents:
        if (parent / "scripts" / "ci_stage.py").is_file():
            return parent
    return None


def evidence_path() -> Path | None:
    override = os.environ.get("CJDOC_CI_EVIDENCE")
    if override:
        return Path(override) / "showcase-stages.json"
    root = _repository_root()
    return root / "target" / "ci-evidence" / "showcase-stages.json" if root else None


@contextmanager
def phase(stage_id: str, kind: str = "site-assemble"):
    """Record the wall time of one pipeline phase, then re-raise on failure."""
    record: dict[str, object] = {"stageId": stage_id, "kind": kind,
                                 "timingSource": "monotonic", "command": []}
    import datetime as _dt
    record["startedAt"] = _dt.datetime.now(_dt.timezone.utc).isoformat(
        timespec="milliseconds").replace("+00:00", "Z")
    started = time.perf_counter()
    try:
        yield record
    except BaseException:
        record.update({"wallMs": round((time.perf_counter() - started) * 1000, 3),
                       "exitCode": 1, "status": "failed"})
        RECORDS.append(record)
        flush()
        raise
    record.update({"wallMs": round((time.perf_counter() - started) * 1000, 3),
                   "exitCode": 0, "status": "passed"})
    RECORDS.append(record)


def flush() -> None:
    """Persist accumulated records; never let timing break generation."""
    path = evidence_path()
    if path is None or not RECORDS:
        return
    try:
        existing: list[dict] = []
        if path.exists():
            document = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(document, dict) and isinstance(document.get("stages"), list):
                existing = document["stages"]
        seen = {(item.get("stageId"), item.get("startedAt")) for item in existing}
        merged = list(existing)
        for record in RECORDS:
            key = (record.get("stageId"), record.get("startedAt"))
            if key not in seen:
                seen.add(key)
                merged.append(record)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + f".tmp{os.getpid()}")
        temporary.write_text(
            json.dumps({"schemaVersion": "cjdoc.ci-stage/1", "stages": merged},
                       ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8", newline="\n")
        os.replace(temporary, path)
    except OSError:
        # Timing evidence is best effort; generation correctness is not.
        pass
