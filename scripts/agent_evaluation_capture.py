#!/usr/bin/env python3
"""Frozen inputs and captured records that every later proof stage trusts.

This module owns the pinned protocol/rubric digests, the frozen scope-to-source
bindings, the budget policy and the one complete capture directory. It never
compiles, runs or scores anything: a stage that needs a different trust rule
adds it here instead of re-deriving capture provenance on its own.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import sys
import tomllib
from typing import Any

sys.dont_write_bytecode = True
try:
    from .strict_json import strict_load
except ImportError:  # Direct script execution.
    from strict_json import strict_load

try:
    import agent_evaluation as evaluation
except ImportError:  # Package execution.
    from . import agent_evaluation as evaluation

REPO = Path(__file__).resolve().parent.parent
PROTOCOL = evaluation.DEFAULT_PROTOCOL
RUBRIC = REPO / "tests/agent/evaluation-rubric.json"
VERIFICATION_DIRECTORY = "verification"
VERIFICATION_NAME = "verification.json"
ADJUDICATION_TEMPLATE_NAME = "adjudication-template.json"
CONSUMER_DIRECTORY = "consumer"

# The frozen protocol names a documentation scope per task; this is the actual
# source mapping those scopes resolve to. Every entry is verified against the
# real manifest (`name` and `version`) before a consumer is built, so a drifted
# checkout fails instead of compiling against an unintended library version.
SCOPE_TABLE: dict[str, dict[str, Any]] = {
    "pocketkit@0.2.0": {
        "requestedVersion": "0.2.0",
        "dependencies": [{"name": "pocketkit",
                          "path": "examples/pocketkit/demo-v2", "version": "0.2.0"}],
    },
    "pocketkit@0.1.0": {
        "requestedVersion": "0.1.0",
        "dependencies": [{"name": "pocketkit",
                          "path": "examples/pocketkit/demo-v1", "version": "0.1.0"}],
    },
    "pocketkit@0.2.0 and pocket_support@0.1.0": {
        "requestedVersion": "0.2.0",
        "dependencies": [
            {"name": "pocketkit", "path": "examples/pocketkit/demo-v2", "version": "0.2.0"},
            {"name": "pocket_support",
             "path": "examples/pocketkit/support-v1", "version": "0.1.0"},
        ],
    },
    "pocketkit@0.2.0; requested-language=en": {
        "requestedVersion": "0.2.0",
        "locale": "en",
        "dependencies": [{"name": "pocketkit",
                          "path": "examples/pocketkit/demo-v2", "version": "0.2.0"}],
    },
    "reexports-fixture": {
        "dependencies": [{"name": "reexport_root",
                          "path": "tests/fixtures/projects/reexports", "version": "0.1.0"}],
    },
    "partial-source-fixture": {
        "dependencies": [{"name": "unsupported_fixture",
                          "path": "tests/fixtures/projects/unsupported", "version": "0.0.0"}],
    },
}


class ProofError(ValueError):
    """The inputs cannot produce an honest proof; nothing is scored."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ProofError(message)


# ---------------------------------------------------------------------------
# Portable labels
# ---------------------------------------------------------------------------


def digest_of(path: Path) -> str:
    return evaluation.digest_of(path)


def digest_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class Labels:
    """Replace every machine-specific root with a stable, portable label."""

    def __init__(self, mapping: list[tuple[Path | str, str]]) -> None:
        self.pairs = sorted(((str(source), label) for source, label in mapping),
                            key=lambda item: len(item[0]), reverse=True)

    def text(self, value: str) -> str:
        for source, label in self.pairs:
            value = value.replace(source, label)
        return value

    def scrub(self, value: Any) -> Any:
        if isinstance(value, str):
            return self.text(value)
        if isinstance(value, list):
            return [self.scrub(item) for item in value]
        if isinstance(value, dict):
            return {self.text(str(key)): self.scrub(item) for key, item in value.items()}
        return value

    def command(self, argv: list[str]) -> list[str]:
        return [self.text(item) for item in argv]


def privacy_violations(value: Any, forbidden: list[str], path: str = "$") -> list[str]:
    """Absolute local roots that must never reach a published artifact."""
    found: list[str] = []
    if isinstance(value, str):
        for token in forbidden:
            if token and token in value:
                found.append(f"{path} leaks {token!r}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found.extend(privacy_violations(item, forbidden, f"{path}[{index}]"))
    elif isinstance(value, dict):
        for key, item in value.items():
            if isinstance(key, str):
                for token in forbidden:
                    if token and token in key:
                        found.append(f"{path} key leaks {token!r}")
            found.extend(privacy_violations(item, forbidden, f"{path}.{key}"))
    return found


# ---------------------------------------------------------------------------
# Frozen inputs, scopes and captured records
# ---------------------------------------------------------------------------


def load_frozen(protocol_path: Path, rubric_path: Path) -> tuple[dict, dict]:
    protocol = evaluation.load_protocol(protocol_path)
    rubric = evaluation.load_rubric(rubric_path, protocol)
    return protocol, rubric


def manifest_package(path: Path) -> dict:
    try:
        with path.open("rb") as stream:
            document = tomllib.load(stream)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise ProofError(f"unreadable project manifest {path.name}: {error}") from error
    package = document.get("package")
    require(isinstance(package, dict), f"{path.name} has no [package] table")
    return package


def resolve_scopes(protocol: dict, project_root: Path) -> dict[str, dict]:
    """Bind every frozen scope to real, version-checked source dependencies."""
    resolved: dict[str, dict] = {}
    for task in protocol["tasks"]:
        scope = task.get("scope") or ""
        entry = SCOPE_TABLE.get(scope)
        require(entry is not None,
                f"task {task['id']} has an unmapped frozen scope: {scope!r}")
        dependencies = []
        for requirement in entry["dependencies"]:
            root = project_root / requirement["path"]
            require(root.is_dir(),
                    f"task {task['id']}: scope source is missing: {requirement['path']}")
            manifest = root / "cjpm.toml"
            require(manifest.is_file(),
                    f"task {task['id']}: scope source has no cjpm.toml: {requirement['path']}")
            package = manifest_package(manifest)
            observed = package.get("name")
            require(observed == requirement["name"],
                    f"task {task['id']}: {requirement['path']} declares package "
                    f"{observed!r}, scope requires {requirement['name']!r}")
            version = package.get("version")
            if requirement.get("version") is not None:
                require(version == requirement["version"],
                        f"task {task['id']}: {requirement['name']} is version "
                        f"{version!r}, the frozen scope requires "
                        f"{requirement['version']!r}")
            dependencies.append({
                "name": requirement["name"],
                "root": root,
                "relativePath": requirement["path"],
                "requestedVersion": requirement.get("version"),
                "manifestVersion": version,
                "manifestSha256": digest_of(manifest),
            })
        resolved[scope] = {
            "scope": scope,
            "requestedVersion": entry.get("requestedVersion"),
            "locale": entry.get("locale"),
            "dependencies": dependencies,
        }
    return resolved


def frozen_sources(protocol: dict, project_root: Path) -> dict[str, list[dict]]:
    """Check that each frozen oracle source reference still exists (never published)."""
    observed: dict[str, list[dict]] = {}
    for task in protocol["tasks"]:
        entries = []
        for part in str(task.get("source") or "").split(";"):
            part = part.strip()
            if not part:
                continue
            reference = part.rsplit(":", 1)[0] if re.search(r":\d", part) else part
            path = project_root / reference
            if path.is_file():
                entries.append({"reference": reference, "state": "file",
                                "sha256": digest_of(path)})
            elif path.is_dir():
                entries.append({"reference": reference, "state": "directory",
                                "files": sum(1 for item in path.rglob("*") if item.is_file())})
            else:
                entries.append({"reference": reference, "state": "missing"})
        observed[task["id"]] = entries
    return observed


def checked_budgets(observed: Any, frozen: dict, where: str) -> dict:
    """Budgets may only be tightened. Relaxation is never a valid observation.

    The frozen budget block also carries non-numeric policy keys (the failure
    rule and the token-accounting rule); those must match exactly, while the
    numeric limits may only be lowered.
    """
    require(isinstance(observed, dict) and observed, f"{where}: no budgets recorded")
    require(set(observed) == set(frozen),
            f"{where}: budget keys differ from the frozen protocol")
    for key, frozen_value in frozen.items():
        value = observed[key]
        if isinstance(frozen_value, bool) or not isinstance(frozen_value, int):
            require(value == frozen_value,
                    f"{where}: budget policy {key} differs from the frozen protocol")
            continue
        require(isinstance(value, int) and not isinstance(value, bool),
                f"{where}: budget {key} is not an integer")
        require(1 <= value <= frozen_value,
                f"{where}: budget {key}={value} exceeds the frozen {frozen_value}; "
                "relaxation is not permitted")
    return dict(observed)


class Capture:
    """One complete evaluator output directory."""

    def __init__(self, output: Path, protocol: dict, rubric: dict,
                 protocol_path: Path, rubric_path: Path) -> None:
        self.output = Path(os.path.abspath(output))
        require(self.output.is_dir(), f"capture output is not a directory: {self.output}")
        manifest_path = self.output / evaluation.MANIFEST_NAME
        require(manifest_path.is_file(),
                f"capture has no {evaluation.MANIFEST_NAME}")
        self.manifest = strict_load(manifest_path, description="run manifest")
        self.manifest_path = manifest_path
        self.protocol = protocol
        self.rubric = rubric
        self.protocol_path = protocol_path
        self.rubric_path = rubric_path
        self.protocol_sha256 = digest_of(protocol_path)
        self.rubric_sha256 = digest_of(rubric_path)
        require(self.manifest.get("schemaVersion") == "cjdoc.agent-evaluation-run/1",
                "run manifest has an unsupported schemaVersion")
        recorded_protocol = (self.manifest.get("protocol") or {}).get("sha256")
        recorded_rubric = (self.manifest.get("rubric") or {}).get("sha256")
        require(recorded_protocol == self.protocol_sha256,
                "captured run used a different frozen protocol file")
        require(recorded_rubric == self.rubric_sha256,
                "captured run used a different frozen rubric file")
        if "sourceCitationBaseline" in protocol:
            require(self.manifest.get("sourceCitationBaseline") == protocol["sourceCitationBaseline"],
                    "captured run used a different frozen source citation baseline")
        self.budgets = checked_budgets(self.manifest.get("budgets"), protocol["budgets"],
                                       "captured run manifest")
        self.records: dict[tuple[str, str], dict] = {}
        self.record_paths: dict[tuple[str, str], Path] = {}
        missing = []
        for task in protocol["tasks"]:
            for arm in evaluation.ARMS:
                path = (self.output / "sessions" / task["id"] / arm
                        / evaluation.RECORD_NAME)
                if not path.is_file():
                    missing.append(f"{task['id']}:{arm}")
                    continue
                record = strict_load(path, description="session record")
                self._check_record(record, task, arm, path)
                self.records[(task["id"], arm)] = record
                self.record_paths[(task["id"], arm)] = path
        require(not missing,
                "capture is incomplete; missing session records: " + ", ".join(missing))

    def _check_record(self, record: dict, task: dict, arm: str, path: Path) -> None:
        label = f"{task['id']}:{arm}"
        require(record.get("schemaVersion") == "cjdoc.agent-evaluation-record/1",
                f"{label}: unsupported record schemaVersion")
        require((record.get("task") or {}).get("id") == task["id"],
                f"{label}: record task id does not match its session path")
        require(record.get("arm") == arm,
                f"{label}: record arm does not match its session path")
        require((record.get("task") or {}).get("scope") == task.get("scope"),
                f"{label}: recorded source scope differs from the frozen task")
        require((record.get("task") or {}).get("prompt") == task.get("prompt"),
                f"{label}: recorded question differs from the frozen task")
        frozen_facts = list(task["requiredFacts"])
        require(list((record.get("task") or {}).get("requiredFacts") or []) == frozen_facts,
                f"{label}: recorded requiredFacts differ from the frozen protocol")
        require((record.get("task") or {}).get("behaviorRequired") is task["behaviorRequired"],
                f"{label}: recorded behaviorRequired differs from the frozen protocol")
        require(record.get("budgets") == self.budgets,
                f"{label}: record budgets differ from the captured run manifest")
        answer = record.get("answer") or {}
        require(isinstance(answer, dict), f"{label}: answer section is malformed")

    def ordered(self) -> list[tuple[str, str]]:
        keys: list[tuple[str, str]] = []
        for task in self.protocol["tasks"]:
            for arm in evaluation.ARMS:
                keys.append((task["id"], arm))
        return keys


def parsed_answer(record: dict, protocol: dict) -> dict:
    """Re-read the captured raw answer with the same parser the runner used."""
    raw = (record.get("answer") or {}).get("raw")
    return evaluation.parse_answer(raw if isinstance(raw, str) else None,
                                  protocol["answerFields"])


def answer_citations(record: dict, protocol: dict) -> list[Any]:
    parsed = parsed_answer(record, protocol)
    body = parsed.get("json") or {}
    citations = body.get("citations")
    return citations if isinstance(citations, list) else []
