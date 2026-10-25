#!/usr/bin/env python3
"""Compile every captured consumer verbatim and adjudicate the frozen Agent comparison.

`verify` uses the selected Cangjie SDK inside a Linux x86-64 bubblewrap sandbox.
It captures the requested local dependency closure, builds fresh static exports,
and invokes cjc once on the exact consumerCode UTF-8 bytes. It never inserts a
package declaration, repairs imports or retries a generated program. Every task
and arm is checkpointed, including missing code and infrastructure failures.

Required programs execute with only runtime libraries, no inherited credentials,
no host home or network, read-only filesystems, bounded logs and a process-group
deadline. The supervisor blocks process creation in runtime consumers. Compiler
and runtime receipts identify their actual executable and source/output bytes.

`template` lists every frozen fact, citation and separately adjudicated dimension.
`report` binds evidence to captured Doc IR hashes and actual source identities.
A zero exit status or printed marker alone is not behavioral proof. Required
behavior also needs a manual whole-program/source/control-flow adequacy review,
exact exercise/check code excerpts, implementation-source evidence and observed
runtime evidence. These are explicit reviewer judgments, not automatic semantic
proof or keyword scoring. Invalid assessments never promote behavior to verified.

Run verify --output "$RUN" --project-root . --sdk-root "$SDK" first; fill the
emitted adjudication template, then run report with --adjudications and --doc-ir
LABEL=PATH. Optional --final PATH overrides the default final-report.json.
`report` refuses final publication while any verification/adjudication gap remains.
`observations` retains measured outcomes without assigning natural-language scores.
Published reports normalize registered local roots; private captures retain the
original bytes used for hashes and compilation.
"""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
from typing import Any

sys.dont_write_bytecode = True
try:
    from .strict_json import strict_dumps, strict_load
except ImportError:  # Direct script execution.
    from strict_json import strict_dumps, strict_load

try:
    import agent_evaluation as evaluation
except ImportError:  # Package execution.
    from . import agent_evaluation as evaluation

try:
    import agent_evaluation_runtime as consumer_runtime
except ImportError:
    from . import agent_evaluation_runtime as consumer_runtime

REPO = Path(__file__).resolve().parent.parent
PROTOCOL = evaluation.DEFAULT_PROTOCOL
RUBRIC = REPO / "tests/agent/evaluation-rubric.json"
VERIFICATION_DIRECTORY = "verification"
VERIFICATION_NAME = "verification.json"
ADJUDICATION_TEMPLATE_NAME = "adjudication-template.json"
CONSUMER_DIRECTORY = "consumer"
VERIFICATION_SCHEMA = "cjdoc.agent-evaluation-consumer-verification/1"
ADJUDICATION_SCHEMA = "cjdoc.agent-evaluation-adjudication/1"
REPORT_SCHEMA = "cjdoc.agent-evaluation-final-report/1"
OBSERVATION_SCHEMA = "cjdoc.agent-evaluation-observations/1"
MAXIMUM_CAPTURED_STREAM_BYTES = consumer_runtime.STREAM_BYTES
DEFAULT_COMPILE_SECONDS = 300
DEFAULT_RUN_SECONDS = 60

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

ADJUDICATED_DIMENSIONS = ("apiSelection", "wrongApiVersion",
                          "signatureAndNamedDefaults", "uncertaintyPreservation")
IDENTITY_DIMENSIONS = ("apiSelection", "wrongApiVersion", "signatureAndNamedDefaults")
FACT_VERDICTS = ("supported", "contradicted", "omitted")
CITATION_VERDICTS = ("verified", "unverified", "rejected")
ASSERTION_VERDICTS = ("observed", "not-observed", "unverified")
EVIDENCE_KINDS = ("source", "doc-ir", "answer")


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


# ---------------------------------------------------------------------------
# Consumer projects
# ---------------------------------------------------------------------------

def initial_consumer(capture: Capture, task: dict, arm: str) -> dict:
    record = capture.records[(task["id"], arm)]
    answer = parsed_answer(record, capture.protocol).get("json") or {}
    code = answer.get("consumerCode", "")
    code = code if isinstance(code, str) else ""
    cached = (record.get("answer") or {}).get("consumerCode")
    entry = {"task": task["id"], "arm": arm,
             "behaviorRequired": task["behaviorRequired"],
             "scope": {"scope": task.get("scope")},
             "consumerCodeBytes": len(code.encode("utf-8")),
             "consumerCodeSha256": digest_text(code),
             "packaging": None, "compile": None, "behavior": None,
             "failure": None, "integrityFailure": None, "state": "pending"}
    if cached is not None and cached != code:
        entry["integrityFailure"] = "cached consumerCode differs from captured raw answer"
    if code == "":
        entry["state"] = "missing-code" if task["behaviorRequired"] else "not-applicable"
        if task["behaviorRequired"]:
            entry["failure"] = {"kind": "missing-consumer-code",
                                "reason": "required task produced no identifiable consumerCode"}
    return entry


def consumer_totals(consumers: list[dict]) -> dict:
    return {"compiled": sum(item["state"] == "compiled" for item in consumers),
            "compileFailed": sum(item["state"] == "compile-failed" for item in consumers),
            "infrastructureFailed": sum(item["state"] == "infrastructure-failed" for item in consumers),
            "missingCode": sum(item["state"] == "missing-code" for item in consumers),
            "notApplicable": sum(item["state"] == "not-applicable" for item in consumers),
            "pending": sum(item["state"] == "pending" for item in consumers),
            "runtimeExecuted": sum((item.get("behavior") or {}).get("state") == "runtime-executed"
                                   for item in consumers),
            "runFailed": sum((item.get("failure") or {}).get("kind") in
                             {"run-failed", "run-timeout", "run-launch-failed", "binary-missing"}
                             for item in consumers)}


def build_consumer(capture: Capture, task: dict, arm: str, scope: dict,
                   root: Path, runtime, library: dict, entry: dict,
                   compile_seconds: float, run_seconds: float) -> None:
    if entry["state"] != "pending":
        return
    answer = parsed_answer(capture.records[(task["id"], arm)], capture.protocol).get("json") or {}
    code = answer.get("consumerCode", "")
    require(isinstance(code, str) and digest_text(code) == entry["consumerCodeSha256"],
            "captured consumer code changed before verification")
    project = root / "tasks" / task["id"] / arm / CONSUMER_DIRECTORY
    project.mkdir(mode=0o700, parents=True)
    entry["scope"].update({"requestedVersion": scope["requestedVersion"], "locale": scope["locale"]})
    entry["dependencies"] = {"sources": library.get("sources", []),
                             "exports": library.get("exports", {}).get("pins", [])}
    bound = library["state"] in ("built", "not_required")
    entry["scopeBinding"] = {"state": "verified" if bound else "unavailable",
        "libraryState": library["state"],
        "failure": None if bound else library.get("failure") or library.get("receipt")}
    if not bound:
        entry["failure"] = {"kind": "requested-library-unavailable",
            "reason": "Exact consumer compilation is still attempted with the SDK; "
                      "it cannot establish compatibility with the requested library."}
    exports = library.get("exports") or {"directories": [], "libraries": [], "pins": []}
    entry["projectLabel"] = runtime.labels.text(str(project))
    compiled = consumer_runtime.compile_consumer(runtime, code, project, exports, compile_seconds)
    entry["packaging"] = compiled["packaging"]
    entry["compile"] = compiled["compile"]
    entry["elapsedMs"] = entry["compile"]["elapsedMs"]
    receipt = entry["compile"]
    if receipt["launchError"]:
        entry["state"] = "infrastructure-failed"
        entry["failure"] = {"kind": "compile-launch-failed", "reason": receipt["launchError"]}
        return
    if receipt["timedOut"] or receipt["exitCode"] != 0:
        entry["state"] = "compile-failed"
        entry["failure"] = {"kind": "compile-timeout" if receipt["timedOut"] else "compile-failed",
                            "reason": "the one executable cjc compilation did not succeed"}
        return
    binary = compiled["binary"]
    if binary is None:
        entry["state"] = "infrastructure-failed"
        entry["failure"] = {"kind": "binary-missing", "reason": "successful compiler exit produced no executable"}
        return
    receipt["binarySha256"] = digest_of(binary)
    receipt["binaryLabel"] = runtime.labels.text(str(binary))
    entry["state"] = "compiled"
    if not bound:
        entry["behavior"] = {"state": "not-attempted", "reason": "requested library binding unavailable"}
        return
    if not task["behaviorRequired"]:
        entry["behavior"] = {"state": "not-required"}
        return
    entry["behavior"] = consumer_runtime.run_consumer(runtime, binary, project, run_seconds)
    run = entry["behavior"]["run"]
    run["binaryLabel"] = runtime.labels.text(str(binary))
    entry["elapsedMs"] += run["elapsedMs"]
    if run["launchError"]:
        entry["failure"] = {"kind": "run-launch-failed", "reason": run["launchError"]}
    elif run["timedOut"]:
        entry["failure"] = {"kind": "run-timeout", "reason": "consumer exceeded its recorded deadline"}
    elif run["exitCode"] != 0:
        entry["failure"] = {"kind": "run-failed", "reason": "consumer exited " + str(run["exitCode"])}


def verify_stage(args: argparse.Namespace, protocol: dict, rubric: dict,
                 capture: Capture) -> dict:
    project_root = Path(args.project_root).resolve(strict=True)
    root = Path(os.path.abspath(args.verification or capture.output / VERIFICATION_DIRECTORY))
    require(not root.exists() or root.is_dir() and not any(root.iterdir()),
            "refusing to reuse a non-empty verification directory")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    sdk_value = args.sdk_root or os.environ.get("CANGJIE_HOME")
    sdk = Path(sdk_value).resolve() if sdk_value else None
    labels = Labels([(root, "<verification>"), (capture.output.resolve(), "<output>"),
                     (project_root, "<repo>"), (Path.home(), "$HOME"),
                     (Path(tempfile.gettempdir()).resolve(), "$TMPDIR")] +
                    ([(sdk, "<sdk>")] if sdk else []))
    consumers = [initial_consumer(capture, task, arm)
                 for task in protocol["tasks"] for arm in evaluation.ARMS]
    rows = {(row["task"], row["arm"]): row for row in consumers}
    path = root / VERIFICATION_NAME
    receipt = {"schemaVersion": VERIFICATION_SCHEMA,
        "generatedBy": "scripts/agent_evaluation_proof.py verify", "state": "in-progress",
        "attemptPolicy": "one executable compilation of each non-empty verbatim consumerCode; "
                         "one run when behaviorRequired; no retries or source repairs",
        "protocol": {"path": evaluation.repo_relative(args.protocol), "sha256": capture.protocol_sha256},
        "rubric": {"path": evaluation.repo_relative(args.rubric), "sha256": capture.rubric_sha256},
        "run": {"label": "<output>", "manifestSha256": digest_of(capture.manifest_path),
                "records": len(capture.records), "budgets": capture.budgets},
        "toolchain": {"sdkRoot": "<sdk>" if sdk else None,
            "environmentPolicy": "explicit allowlist; no inherited environment or credentials",
            "compileTimeoutSeconds": args.compile_seconds, "runTimeoutSeconds": args.run_seconds},
        "scopes": {}, "frozenSources": {}, "consumers": consumers,
        "totals": consumer_totals(consumers), "setupFailures": []}

    def checkpoint():
        receipt["totals"] = consumer_totals(consumers)
        evaluation.write_json(path, labels.scrub(receipt))

    checkpoint()
    runtime = None
    try:
        require(sdk is not None, "pass the pinned SDK with --sdk-root or CANGJIE_HOME")
        runtime = consumer_runtime.ConsumerRuntime(sdk, labels)
        preflight = root / "preflight"
        preflight.mkdir(mode=0o700)
        receipt["toolchain"]["preflight"] = runtime.preflight(preflight)
        for name, executable in (("cjc", runtime.cjc), ("cjpm", runtime.cjpm)):
            probe_root = root / ("tool-" + name)
            probe_root.mkdir(mode=0o700)
            probe = runtime.execute([str(executable), "-v"], cwd=probe_root,
                scratch=probe_root / "scratch", readonly=[], writable=[], compiler=True,
                seconds=30, logs=probe_root / "logs")
            receipt["toolchain"][name] = {"label": labels.text(str(executable)),
                "sha256": digest_of(executable), "version":
                (probe["stdout"]["text"] + probe["stderr"]["text"]).strip().splitlines()[0]
                if (probe["stdout"]["text"] + probe["stderr"]["text"]).strip() else None,
                "probe": {key: probe[key] for key in ("exitCode", "timedOut", "launchError")}}
            require(probe["exitCode"] == 0 and not probe["timedOut"] and not probe["launchError"],
                    name + " namespace tool probe failed")
    except Exception as error:
        receipt["setupFailures"].append({"stage": "toolchain", "reason": labels.text(str(error))})
        runtime = None
    checkpoint()
    scopes, libraries, library_keys = {}, {}, {}
    for task in protocol["tasks"]:
        name = task.get("scope") or ""
        if name not in scopes:
            try:
                scope = resolve_scopes({"tasks": [task]}, project_root)[name]
                scopes[name] = scope
                closure = consumer_runtime.source_closure(project_root,
                    [dependency["root"] for dependency in scope["dependencies"]])
                receipt["scopes"][name] = {"requestedVersion": scope["requestedVersion"],
                    "locale": scope["locale"], "dependencies": [
                        {key: labels.text(str(value)) if isinstance(value, Path) else value
                         for key, value in dependency.items()} for dependency in scope["dependencies"]],
                    "sourceIdentities": [{"path": item["relative"].as_posix(), "name": item["name"],
                        "version": item["version"], "identity": item["identity"]} for item in closure]}
                library_keys[name] = tuple(sorted((str(item["root"]), item["identity"]) for item in closure))
            except Exception as error:
                scopes[name] = None
                receipt["setupFailures"].append({"stage": "scope", "scope": name,
                                                 "reason": labels.text(str(error))})
            checkpoint()
        scope = scopes[name]
        for arm in evaluation.ARMS:
            row = rows[(task["id"], arm)]
            if row["state"] != "pending":
                continue
            try:
                require(runtime is not None and scope is not None, "toolchain or source-scope setup failed")
                key = library_keys[name]
                if key not in libraries:
                    library_root = root / "libraries" / str(len(libraries))
                    library_root.mkdir(mode=0o700, parents=True)
                    try:
                        built = consumer_runtime.build_libraries(runtime, scope, project_root,
                                                               library_root, float(args.compile_seconds))
                    except Exception as error:
                        built = {"state": "setup-failed", "failure": labels.text(str(error))}
                    libraries[key] = built
                library = libraries[key]
                build_consumer(capture, task, arm, scope, root, runtime, library, row,
                               float(args.compile_seconds), float(args.run_seconds))
            except Exception as error:
                if row["state"] != "compiled":
                    row["state"] = "infrastructure-failed"
                row["failure"] = {"kind": "verification-infrastructure", "reason": labels.text(str(error))}
            finally:
                checkpoint()
    receipt["libraries"] = [{key: value for key, value in library.items() if key != "exports"}
                            | ({"exports": library["exports"]["pins"]} if "exports" in library else {})
                            for library in libraries.values()]
    receipt["frozenSources"] = frozen_sources(protocol, project_root)
    receipt["state"] = "complete"
    checkpoint()
    template_path = root / ADJUDICATION_TEMPLATE_NAME
    evaluation.write_json(template_path, template_stage(capture, protocol))
    return {"path": path, "receipt": labels.scrub(receipt), "template": template_path}


# ---------------------------------------------------------------------------
# Adjudication validation
# ---------------------------------------------------------------------------


class Evidence:
    """Source-confined, captured-file and frozen-library-bound evidence."""

    def __init__(self, project_root: Path, doc_ir: dict[str, Path],
                 capture: Capture, verification: dict) -> None:
        self.project_root = project_root.resolve(strict=True)
        self.doc_ir = doc_ir
        self._documents = {}
        self._declarations = {}
        self._doc_digests = {}
        self._bindings = {}
        self._source_reads = {}
        self._primary = {}
        pool = set()
        for scope_name in dict.fromkeys(task.get("scope") or "" for task in capture.protocol["tasks"]):
            requirement = SCOPE_TABLE[scope_name]
            roots = [self.project_root / item["path"] for item in requirement["dependencies"]]
            closure = consumer_runtime.source_closure(self.project_root, roots)
            recorded = ((verification.get("receipt") or {}).get("scopes") or {}).get(scope_name) or {}
            observed = [{"path": item["relative"].as_posix(), "name": item["name"],
                         "version": item["version"], "identity": item["identity"]} for item in closure]
            require(recorded.get("sourceIdentities") == observed,
                    "verification source closure differs from current frozen scope " + scope_name)
            for item in observed:
                pool.add((item["name"], item["version"], item["identity"]))
            if requirement["dependencies"]:
                first = requirement["dependencies"][0]
                primary = next(item for item in observed if item["path"] == first["path"])
                self._primary[scope_name] = primary
        captured_digests = {item.get("sha256") for item in capture.manifest.get("snapshots", [])
                            if isinstance(item, dict)}
        for label, path in doc_ir.items():
            require(path.is_file() and not path.is_symlink(), "Doc IR must be a regular captured file")
            before = digest_of(path)
            require(before in captured_digests,
                    "Doc IR " + label + " bytes were not captured in the evaluator run")
            document = strict_load(path, description="Doc IR " + label)
            require(digest_of(path) == before, "Doc IR changed while loading " + label)
            require(isinstance(document, dict) and document.get("schemaVersion") == "cjdoc.doc-ir/16",
                    "Doc IR " + label + " is not the current captured v16 format")
            self._documents[label] = document
            self._doc_digests[label] = before
            self._declarations[label] = _declaration_index(document)
            bindings = []
            for module in document.get("modules", []):
                for dependency in document.get("dependencies", []):
                    # componentModuleId, not the consuming moduleId, owns these
                    # declarations. Imported sets with a local 'root' id are not
                    # evidence for this snapshot's unrelated root declarations.
                    if dependency.get("componentModuleId") != module.get("id"):
                        continue
                    key = (module.get("name"), dependency.get("version"), dependency.get("identity"))
                    if (dependency.get("kind") != "source" or
                            dependency.get("state") not in ("observed", "verified") or key not in pool):
                        continue
                    binding = {"moduleId": module["id"], "library": key[0],
                               "apiVersion": key[1], "sourceIdentity": key[2],
                               "snapshotSha256": before}
                    if binding not in bindings:
                        bindings.append(binding)
            self._bindings[label] = bindings

    def digest(self, path: Path) -> str:
        if path not in self._source_reads:
            content = path.read_bytes()
            self._source_reads[path] = (hashlib.sha256(content).hexdigest(), content)
        return self._source_reads[path][0]

    def check_current_inputs(self) -> None:
        for label, path in self.doc_ir.items():
            require(digest_of(path) == self._doc_digests[label], "Doc IR changed after evidence validation")
        for path, (digest, _) in self._source_reads.items():
            require(not path.is_symlink() and digest_of(path) == digest,
                    "source evidence changed after validation")

    def check(self, item: Any, where: str) -> list[str]:
        if not isinstance(item, dict):
            return [where + ": evidence item must be an object"]
        kind = item.get("kind")
        if kind == "source":
            return self._check_source(item, where)
        if kind == "doc-ir":
            return self._check_doc_ir(item, where)
        if kind != "answer":
            return [where + ": unknown evidence kind"]
        quote = item.get("quote")
        return [] if isinstance(quote, str) and quote.strip() else [where + ": answer evidence needs a quote"]

    def _check_source(self, item: dict, where: str) -> list[str]:
        relative = item.get("path")
        if not isinstance(relative, str) or not relative:
            return [where + ": source evidence needs a path"]
        candidate = Path(relative)
        if candidate.is_absolute() or ".." in candidate.parts:
            return [where + ": source evidence must be project-root relative"]
        path = self.project_root / candidate
        if any(part.is_symlink() for part in [path, *path.parents] if part != self.project_root):
            return [where + ": symbolic source evidence is not admitted"]
        if not path.is_file() or not path.resolve().is_relative_to(self.project_root):
            return [where + ": source evidence is missing or outside the frozen root"]
        problems = []
        if item.get("sha256") != self.digest(path):
            problems.append(where + ": source evidence digest differs")
        try:
            text = self._source_reads[path][1].decode("utf-8")
        except UnicodeDecodeError:
            return problems + [where + ": source evidence is not UTF-8"]
        start, end = item.get("lineStart"), item.get("lineEnd")
        if start is not None or end is not None:
            if type(start) is not int or type(end) is not int or not 1 <= start <= end:
                return problems + [where + ": invalid source line range"]
            lines = text.splitlines()
            if end > len(lines):
                return problems + [where + ": source line range exceeds the file"]
            text = "\n".join(lines[start - 1:end])
        if "excerpt" in item and (not isinstance(item["excerpt"], str) or
                                  not item["excerpt"] or item["excerpt"] not in text):
            problems.append(where + ": source excerpt is not present in the pinned bytes")
        return problems

    def _eligible_bindings(self, item: dict) -> list[dict]:
        label = item.get("snapshot")
        identifier = item.get("declarationId")
        declaration = self._declarations.get(label, {}).get(identifier) if identifier else None
        module = declaration.get("moduleId") if declaration else item.get("moduleId")
        return [binding for binding in self._bindings.get(label, [])
                if (module is None or binding["moduleId"] == module) and
                all(field not in item or item[field] == binding[field]
                    for field in ("library", "apiVersion", "sourceIdentity"))]

    def _check_doc_ir(self, item: dict, where: str) -> list[str]:
        label = item.get("snapshot")
        if label not in self._documents:
            return [where + ": Doc IR evidence names an uncaptured snapshot"]
        identifier = item.get("declarationId")
        if identifier is not None and identifier not in self._declarations[label]:
            return [where + ": Doc IR evidence names an unknown declaration"]
        if not self._eligible_bindings(item):
            return [where + ": Doc IR library/version/module/source identity is not bound to frozen source"]
        field = item.get("field")
        if not isinstance(field, str) or not field:
            return [where + ": Doc IR evidence needs a field"]
        value = self._declarations[label][identifier] if identifier is not None else self._documents[label]
        for part in field.split("."):
            if not isinstance(value, dict) or part not in value:
                return [where + ": claimed Doc IR field does not exist"]
            value = value[part]
        if "contains" not in item and "equals" not in item:
            return [where + ": Doc IR evidence needs a concrete contains or equals claim"]
        rendered = value if isinstance(value, str) else strict_dumps(value, ensure_ascii=False)
        if "contains" in item and (not isinstance(item["contains"], str) or
                                   not item["contains"] or item["contains"] not in rendered):
            return [where + ": claimed Doc IR text is not present"]
        if "equals" in item and strict_dumps(value, sort_keys=True) != strict_dumps(item["equals"], sort_keys=True):
            return [where + ": claimed Doc IR value differs"]
        return []

    def selects_primary(self, items: list[dict], task: dict) -> bool:
        primary = self._primary.get(task.get("scope") or "")
        if not primary:
            return False
        for item in items:
            if item.get("kind") == "source":
                path = Path(item.get("path") or "")
                if path.is_relative_to(Path(primary["path"])):
                    return True
            if item.get("kind") == "doc-ir":
                for binding in self._eligible_bindings(item):
                    if (binding["library"], binding["apiVersion"], binding["sourceIdentity"]) == (
                            primary["name"], primary["version"], primary["identity"]):
                        return True
        return False


def _declaration_index(document: dict) -> dict[str, dict]:
    declarations = document.get("declarations")
    require(isinstance(declarations, list), "captured Doc IR has no flat declaration collection")
    index = {}
    for declaration in declarations:
        require(isinstance(declaration, dict) and isinstance(declaration.get("id"), str),
                "captured declaration is malformed")
        identifier = declaration["id"]
        require(identifier not in index, "captured Doc IR repeats a declaration identity")
        index[identifier] = declaration
    return index


def check_dimension(name: str, entry: Any, where: str,
                    evidence: Evidence, task: dict) -> list[str]:
    if not isinstance(entry, dict):
        return [f"{where}: dimension {name} must be an object"]
    problems = []
    items = entry.get("evidence")
    if not isinstance(items, list) or not items:
        problems.append(f"{where}: dimension {name} needs explicit evidence")
        items = []
    for position, item in enumerate(items):
        problems.extend(evidence.check(item, f"{where}: dimension {name} evidence[{position}]"))
    kinds = {item.get("kind") for item in items if isinstance(item, dict)}
    if name in IDENTITY_DIMENSIONS and not ({"source", "doc-ir"} & kinds):
        problems.append(f"{where}: dimension {name} is an identity judgment and needs "
                        "source or Doc IR evidence")
    value = entry.get("value")
    if name == "apiSelection":
        if not (type(value) is int and value in (0, 1) or value == "not-applicable"):
            problems.append(f"{where}: apiSelection value must be 1, 0 or not-applicable")
        if value == "not-applicable" and not str(entry.get("reason") or "").strip():
            problems.append(f"{where}: apiSelection not-applicable needs a reason")
        if value == 1 and not evidence.selects_primary(items, task):
            problems.append(where + ": API selection evidence does not bind the requested primary library/version")
    elif name == "uncertaintyPreservation":
        if type(value) is not int or value not in (0, 1):
            problems.append(f"{where}: uncertaintyPreservation value must be 1 or 0")
    else:
        if not (isinstance(value, int) and not isinstance(value, bool) and value >= 0):
            problems.append(f"{where}: {name} value must be a non-negative count")
    return problems


def check_assertion_evidence(item: Any, behavior: dict, where: str) -> list[str]:
    if not isinstance(item, dict):
        return [f"{where}: assertion evidence must be an object"]
    kind = item.get("kind")
    run = behavior.get("run") or {}
    if kind == "stdout":
        quote = item.get("quote")
        text = (run.get("stdout") or {}).get("text") or ""
        if not isinstance(quote, str) or not quote.strip() or quote not in text:
            return [f"{where}: stdout quote does not occur in the captured consumer output"]
        return []
    if kind == "stderr":
        quote = item.get("quote")
        text = (run.get("stderr") or {}).get("text") or ""
        if not isinstance(quote, str) or not quote.strip() or quote not in text:
            return [f"{where}: stderr quote does not occur in the captured consumer output"]
        return []
    if kind == "exit-code":
        expected = item.get("exitCode")
        if type(expected) is not int or expected != run.get("exitCode"):
            return [f"{where}: claimed exit code {expected!r} is not the observed "
                    f"{run.get('exitCode')!r}"]
        return []
    return [f"{where}: assertion evidence kind must be stdout, stderr or exit-code"]


def check_behavior_review(review: Any, code: str, where: str) -> list[str]:
    if not isinstance(review, dict):
        return [where + ": runtime behavior requires a separate source/control-flow review"]
    problems = []
    if review.get("method") != "manual-source-and-control-flow-audit":
        problems.append(where + ": behavior review must identify its manual audit boundary")
    if review.get("consumerCodeSha256") != digest_text(code):
        problems.append(where + ": behavior review describes different consumer bytes")
    if review.get("verdict") not in ("adequate", "inadequate", "unverified"):
        problems.append(where + ": behavior review verdict is invalid")
    quote = review.get("codeQuote")
    if not isinstance(quote, str) or not quote.strip() or quote not in code:
        problems.append(where + ": behavior review needs an actual consumer-code excerpt")
    if not isinstance(review.get("reason"), str) or not review["reason"].strip():
        problems.append(where + ": behavior review needs its source-backed adequacy rationale")
    if review.get("verdict") == "adequate" and review.get("coversTaskBoundaries") is not True:
        problems.append(where + ": an adequate review must cover the frozen task boundaries")
    return problems


def check_behavior_assertion(item: Any, code: str, behavior: dict,
                             evidence: Evidence, where: str) -> list[str]:
    if not isinstance(item, dict):
        return [where + ": assertion must be an object"]
    problems = []
    if not isinstance(item.get("assertion"), str) or not item["assertion"].strip():
        problems.append(where + ": assertion text is required")
    if item.get("verdict") not in ASSERTION_VERDICTS:
        problems.append(where + ": assertion verdict is invalid")
    for field in ("exerciseCode", "checkCode"):
        quote = item.get(field)
        if not isinstance(quote, str) or not quote.strip() or quote not in code:
            problems.append(where + ": " + field + " must quote the exact consumer program")
    sources = item.get("sourceEvidence")
    if not isinstance(sources, list) or not sources:
        problems.append(where + ": behavior assertion needs implementation-source evidence")
        sources = []
    for index, source in enumerate(sources):
        if not isinstance(source, dict) or source.get("kind") != "source":
            problems.append(where + ": implementation evidence must name frozen source")
        else:
            problems.extend(evidence.check(source, where + ":source[" + str(index) + "]"))
    problems.extend(check_assertion_evidence(item.get("evidence"), behavior, where))
    return problems


def validate_assessment(assessment: Any, task: dict, arm: str, record: dict,
                        protocol: dict, behavior: dict, evidence: Evidence,
                        where: str) -> tuple[list[str], dict | None]:
    """Validate one (task, arm) assessment completely; return gaps and a summary."""
    if not isinstance(assessment, dict):
        return [f"{where}: assessment must be an object"], None
    problems: list[str] = []
    parsed = parsed_answer(record, protocol)
    raw = (record.get("answer") or {}).get("raw")
    raw_text = raw if isinstance(raw, str) else ""
    has_answer = bool(parsed.get("present"))
    frozen = list(task["requiredFacts"])

    facts = assessment.get("requiredFacts")
    summaries = []
    if not isinstance(facts, list):
        problems.append(f"{where}: requiredFacts must be a list")
        facts = []
    seen: dict[str, int] = {}
    for position, item in enumerate(facts):
        entry_where = f"{where}: requiredFacts[{position}]"
        if not isinstance(item, dict):
            problems.append(f"{entry_where}: must be an object")
            continue
        fact = item.get("fact")
        if fact not in frozen:
            problems.append(f"{entry_where}: {fact!r} is not a frozen required fact")
            continue
        if fact in seen:
            problems.append(f"{entry_where}: duplicate judgment for {fact!r}")
            continue
        seen[fact] = position
        verdict = item.get("verdict")
        if verdict not in FACT_VERDICTS:
            problems.append(f"{entry_where}: verdict must be one of {list(FACT_VERDICTS)}")
        quote = item.get("answerQuote")
        if has_answer:
            if not isinstance(quote, str) or not quote.strip():
                problems.append(f"{entry_where}: supported/contradicted/omitted judgments "
                                "need a verbatim answer quote")
            elif quote not in raw_text:
                problems.append(f"{entry_where}: answer quote does not occur verbatim in "
                                "the captured answer")
        else:
            if quote not in (None, ""):
                problems.append(f"{entry_where}: there is no captured answer to quote")
            if verdict != "omitted":
                problems.append(f"{entry_where}: without a captured answer the fact "
                                "can only be omitted")
        items = item.get("evidence")
        if verdict in ("supported", "contradicted"):
            if not isinstance(items, list) or not items:
                problems.append(f"{entry_where}: {verdict} needs source/Doc IR evidence")
                items = []
        elif items is None:
            items = []
        elif not isinstance(items, list):
            problems.append(f"{entry_where}: evidence must be a list")
            items = []
        for index, item_evidence in enumerate(items):
            problems.extend(evidence.check(item_evidence,
                                           f"{entry_where}: evidence[{index}]"))
        summaries.append({"fact": fact, "verdict": verdict,
                          "answerQuote": quote if isinstance(quote, str) else "",
                          "evidence": items})
    missing = [fact for fact in frozen if fact not in seen]
    if missing:
        problems.append(f"{where}: no judgment for frozen facts: "
                        + "; ".join(missing))

    citations = answer_citations(record, protocol)
    judged = assessment.get("citations")
    citation_summaries = []
    if not isinstance(judged, list):
        problems.append(f"{where}: citations must be a list (may be empty)")
        judged = []
    indices = []
    for position, item in enumerate(judged):
        entry_where = f"{where}: citations[{position}]"
        if not isinstance(item, dict):
            problems.append(f"{entry_where}: must be an object")
            continue
        index = item.get("index")
        if not (isinstance(index, int) and not isinstance(index, bool)):
            problems.append(f"{entry_where}: index must be an integer")
            continue
        if not (0 <= index < len(citations)):
            problems.append(f"{entry_where}: index {index} is outside the "
                            f"{len(citations)} captured citations")
            continue
        if index in indices:
            problems.append(f"{entry_where}: duplicate judgment for citation {index}")
            continue
        indices.append(index)
        verdict = item.get("verdict")
        if verdict not in CITATION_VERDICTS:
            problems.append(f"{entry_where}: verdict must be one of "
                            f"{list(CITATION_VERDICTS)}")
        items = item.get("evidence")
        if verdict in ("verified", "rejected"):
            if not isinstance(items, list) or not items:
                problems.append(f"{entry_where}: {verdict} citations need evidence")
                items = []
        elif items is None:
            items = []
        elif not isinstance(items, list):
            problems.append(f"{entry_where}: evidence must be a list")
            items = []
        for offset, item_evidence in enumerate(items):
            problems.extend(evidence.check(item_evidence,
                                           f"{entry_where}: evidence[{offset}]"))
        citation_summaries.append({"index": index, "verdict": verdict,
                                   "evidence": items,
                                   "citation": citations[index]})
    absent = [index for index in range(len(citations)) if index not in indices]
    if absent:
        problems.append(f"{where}: citations not judged: "
                        + ", ".join(str(index) for index in absent))

    dimensions = assessment.get("dimensions")
    if not isinstance(dimensions, dict):
        problems.append(f"{where}: dimensions must be an object")
        dimensions = {}
    for name in ADJUDICATED_DIMENSIONS:
        problems.extend(check_dimension(name, dimensions.get(name), where, evidence, task))
    extra_dimensions = sorted(set(dimensions) - set(ADJUDICATED_DIMENSIONS))
    if extra_dimensions:
        problems.append(f"{where}: measured dimensions must not be adjudicated: "
                        + ", ".join(extra_dimensions))

    assertions = assessment.get("behaviorAssertions")
    review = assessment.get("behaviorReview")
    assertion_summaries = []
    if task["behaviorRequired"] and behavior.get("state") == "runtime-executed":
        body = parsed.get("json") or {}
        code = body.get("consumerCode", "")
        code = code if isinstance(code, str) else ""
        problems.extend(check_behavior_review(review, code, where))
        if not isinstance(assertions, list):
            problems.append(where + ": behaviorAssertions must be a list")
            assertions = []
        if isinstance(review, dict) and review.get("verdict") == "adequate" and not assertions:
            problems.append(where + ": an adequate behavior claim needs executed boundary checks")
        for position, item in enumerate(assertions):
            problems.extend(check_behavior_assertion(item, code, behavior, evidence,
                where + ":behaviorAssertions[" + str(position) + "]"))
            if isinstance(item, dict):
                assertion_summaries.append(item)
    elif assertions not in (None, []) and not isinstance(assertions, list):
        problems.append(where + ": behaviorAssertions must be a list")

    contract_omissions = sum(1 for item in summaries if item["verdict"] != "supported")
    summary = {
        "requiredFacts": summaries,
        "contractOmissions": contract_omissions,
        "requiredFactDenominator": len(frozen),
        "citations": citation_summaries,
        "citationDenominator": len(citations),
        "dimensions": dimensions,
        "behaviorAssertions": assertion_summaries,
        "behaviorReview": review,
    }
    return problems, summary


# ---------------------------------------------------------------------------
# Final states and aggregation
# ---------------------------------------------------------------------------


def consumer_compile_state(receipt: dict | None, task: dict, record: dict) -> str:
    if receipt is None or receipt.get("state") == "pending":
        return "verification-outstanding"
    if receipt.get("state") == "compiled":
        return "compiled-without-requested-library" if (receipt.get("scopeBinding") or {}).get("state") == "unavailable" else "compiled"
    return {"compile-failed": "failed", "missing-code": "missing-code",
            "not-applicable": "not-applicable"}.get(receipt.get("state"), "verification-outstanding")


def consumer_behavior_state(task: dict, record: dict, receipt: dict | None,
                           assessment: dict | None) -> str:
    if not task["behaviorRequired"]:
        return "not-required"
    if receipt is None or receipt.get("state") == "pending":
        return "verification-outstanding"
    if receipt.get("state") == "missing-code":
        return "failure-missing-code"
    if receipt.get("state") != "compiled":
        return "not-verified-compile-failed"
    behavior = receipt.get("behavior") or {}
    if behavior.get("state") != "runtime-executed":
        return "not-verified-no-runtime"
    run = behavior.get("run") or {}
    if run.get("timedOut"):
        return "runtime-timeout"
    if run.get("launchError") or run.get("exitCode") != 0:
        return "runtime-failed"
    if not assessment:
        return "runtime-executed-behavior-unverified"
    review = assessment.get("behaviorReview") or {}
    if review.get("verdict") == "inadequate":
        return "failed"
    if review.get("verdict") != "adequate" or review.get("coversTaskBoundaries") is not True:
        return "runtime-executed-behavior-unverified"
    assertions = assessment.get("behaviorAssertions") or []
    if not assertions:
        return "runtime-executed-behavior-unverified"
    verdicts = {item.get("verdict") for item in assertions}
    if "not-observed" in verdicts:
        return "failed"
    return "verified" if verdicts == {"observed"} else "runtime-executed-behavior-unverified"


COMPILE_FAILURE_STATES = ("missing-code", "failed", "verification-outstanding", "compiled-without-requested-library")
BEHAVIOR_FAILURE_STATES = ("runtime-timeout", "runtime-failed", "failed",
                           "failure-missing-code", "not-verified-compile-failed",
                           "not-verified-no-runtime")


def row_for(capture: Capture, task: dict, arm: str, receipt: dict | None,
            assessment: dict | None, assessment_errors: list[str],
            adjudicated: dict | None, protocol: dict) -> dict:
    record = capture.records[(task["id"], arm)]
    classification = evaluation.classify(record)
    parsed = parsed_answer(record, protocol)
    compile_state = consumer_compile_state(receipt, task, record)
    valid_assessment = adjudicated if not assessment_errors else None
    behavior_state = consumer_behavior_state(task, record, receipt, valid_assessment)
    dimensions = valid_assessment.get("dimensions") if valid_assessment else {}
    tool_use = record.get("toolUse") or {}
    client = record.get("client") or {}
    answer = record.get("answer") or {}
    row = {
        "task": task["id"],
        "arm": arm,
        "ordinal": record.get("ordinal"),
        "armPosition": record.get("armPosition"),
        "scope": task.get("scope"),
        "behaviorRequired": task["behaviorRequired"],
        "record": {"path": (capture.record_paths[(task["id"], arm)]
                            .relative_to(capture.output).as_posix()),
                   "sha256": digest_of(capture.record_paths[(task["id"], arm)])},
        "model": {
            "outcome": classification["taskOutcome"],
            "causes": classification["causes"],
            "failureReasons": classification["failureReasons"],
            "clientError": classification["clientError"],
            "budgetFailure": classification["budgetFailure"],
            "budgetFailures": classification["budgetFailures"],
            "contractBreaches": classification["contractBreaches"],
            "answerMissing": classification["answerMissing"],
            "serverContact": classification["serverContact"],
            "recordedConsumerCompile": classification["consumerCompile"],
            "recordedConsumerBehavior": classification["consumerBehavior"],
        },
        "answer": {
            "present": bool(answer.get("present")),
            "missingFields": answer.get("missingFields"),
            "extraFields": answer.get("extraFields"),
            "parseError": answer.get("parseError"),
            "citations": len(answer_citations(record, protocol)),
            "consumerCodeBytes": len((answer.get("consumerCode") or "").encode("utf-8")),
            "consumerCode": answer.get("consumerCode") or "",
            "raw": answer.get("raw"),
            "rawSha256": digest_text(answer["raw"]) if isinstance(answer.get("raw"), str)
            else None,
        },
        "toolUse": {
            "calls": tool_use.get("calls"),
            "resultBytes": tool_use.get("resultBytes"),
            "elapsedMs": (client.get("process") or {}).get("elapsedMs"),
            "usage": client.get("usage"),
            "measurementGaps": record.get("measurementGaps") or [],
            "note": "copied from the captured record; never re-derived or deduplicated",
        },
        "consumer": {
            "compile": compile_state,
            "behavior": behavior_state,
            "receipt": None if receipt is None else {
                "task": receipt["task"], "arm": receipt["arm"],
                "state": receipt["state"],
                "consumerCodeSha256": receipt.get("consumerCodeSha256"),
                "packaging": receipt.get("packaging"),
                "dependencies": receipt.get("dependencies"),
                "projectLabel": receipt.get("projectLabel"),
                "compileExitCode": (receipt.get("compile") or {}).get("exitCode"),
                "compileTimedOut": (receipt.get("compile") or {}).get("timedOut"),
                "compileElapsedMs": (receipt.get("compile") or {}).get("elapsedMs"),
                "run": ((receipt.get("behavior") or {}).get("run") or None),
            },
            "failure": (receipt or {}).get("failure"),
        },
        "adjudication": {
            "state": ("complete" if adjudicated and not assessment_errors else
                      "missing" if adjudicated is None else "invalid"),
            "errors": assessment_errors,
            "requiredFacts": (adjudicated or {}).get("requiredFacts", []),
            "contractOmissions": (adjudicated or {}).get("contractOmissions"),
            "requiredFactDenominator": (adjudicated or {}).get(
                "requiredFactDenominator", len(task["requiredFacts"])),
            "citations": (adjudicated or {}).get("citations", []),
            "citationDenominator": (adjudicated or {}).get("citationDenominator", 0),
            "behaviorAssertions": (adjudicated or {}).get("behaviorAssertions", []),
            "behaviorReview": (adjudicated or {}).get("behaviorReview"),
            "apiSelection": _dimension_value(dimensions, "apiSelection"),
        },
        "dimensions": {
            "apiSelection": _api_value(dimensions),
            "wrongApiVersion": _count_value(dimensions, "wrongApiVersion"),
            "signatureAndNamedDefaults": _count_value(dimensions,
                                                     "signatureAndNamedDefaults"),
            "contractOmissions": (valid_assessment or {}).get("contractOmissions"),
            "sourceAndDocumentCitations": _citation_counts(valid_assessment),
            "uncertaintyPreservation": _score_value(dimensions,
                                                   "uncertaintyPreservation"),
            "readBytes": tool_use.get("resultBytes"),
            "toolCalls": tool_use.get("calls"),
            "elapsedMs": (client.get("process") or {}).get("elapsedMs"),
            "consumerCompile": compile_state,
            "consumerBehavior": behavior_state,
        },
    }
    return row


def _dimension_value(dimensions: dict, name: str) -> Any:
    entry = dimensions.get(name)
    return entry.get("value") if isinstance(entry, dict) else None


def _api_value(dimensions: dict) -> Any:
    value = _dimension_value(dimensions, "apiSelection")
    return value if value in (0, 1) else None


def _count_value(dimensions: dict, name: str) -> int | None:
    value = _dimension_value(dimensions, name)
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def _score_value(dimensions: dict, name: str) -> int | None:
    value = _dimension_value(dimensions, name)
    return value if value in (0, 1) else None


def _citation_counts(adjudicated: dict | None) -> dict:
    entries = (adjudicated or {}).get("citations") or []
    return {
        "verified": sum(1 for item in entries if item.get("verdict") == "verified"),
        "unverified": sum(1 for item in entries if item.get("verdict") == "unverified"),
        "rejected": sum(1 for item in entries if item.get("verdict") == "rejected"),
        "denominator": (adjudicated or {}).get("citationDenominator", 0),
    }


def aggregate(rows: list[dict], protocol: dict, rubric: dict) -> dict:
    """Every rubric dimension with raw sums and explicit denominators."""
    declare = protocol["scoreDimensions"]
    totals: dict[str, dict] = {}
    for arm in evaluation.ARMS:
        arm_rows = [row for row in rows if row["arm"] == arm]
        if not arm_rows:
            continue
        api_applicable = [row for row in arm_rows
                          if row["dimensions"]["apiSelection"] is not None]
        api_not_applicable = [row["task"] for row in arm_rows
                              if (row["adjudication"].get("apiSelection")
                                  == "not-applicable")]
        citations = [row["dimensions"]["sourceAndDocumentCitations"] for row in arm_rows]
        behavior_denominator = sum(1 for row in arm_rows
                                   if row["behaviorRequired"])
        compile_states: dict[str, int] = {}
        for row in arm_rows:
            state = row["dimensions"]["consumerCompile"]
            compile_states[state] = compile_states.get(state, 0) + 1
        behavior_states: dict[str, int] = {}
        for row in arm_rows:
            if row["behaviorRequired"]:
                state = row["dimensions"]["consumerBehavior"]
                behavior_states[state] = behavior_states.get(state, 0) + 1
        totals[arm] = {
            "tasks": len(arm_rows),
            "dimensions": {
                "apiSelection": {
                    "sum": sum(row["dimensions"]["apiSelection"] for row in api_applicable),
                    "scored": len(api_applicable),
                    "denominator": len(arm_rows),
                    "notApplicable": api_not_applicable,
                    "unadjudicated": [row["task"] for row in arm_rows
                                      if row["adjudication"]["state"] != "complete"],
                },
                "wrongApiVersion": {
                    "sum": sum(row["dimensions"]["wrongApiVersion"] or 0 for row in arm_rows),
                    "denominator": len(arm_rows),
                    "unit": "incorrect selected or cited API scope",
                },
                "signatureAndNamedDefaults": {
                    "sum": sum(row["dimensions"]["signatureAndNamedDefaults"] or 0
                               for row in arm_rows),
                    "denominator": len(arm_rows),
                    "unit": "required signature fact",
                },
                "contractOmissions": {
                    "sum": sum(row["dimensions"]["contractOmissions"] or 0
                               for row in arm_rows),
                    "requiredFactDenominator": sum(row["adjudication"].get(
                        "requiredFactDenominator") or 0 for row in arm_rows),
                    "unit": "requiredFacts item",
                },
                "sourceAndDocumentCitations": {
                    "verified": sum(item["verified"] for item in citations),
                    "unverified": sum(item["unverified"] for item in citations),
                    "rejected": sum(item["rejected"] for item in citations),
                    "denominator": sum(item["denominator"] for item in citations),
                },
                "uncertaintyPreservation": {
                    "sum": sum(row["dimensions"]["uncertaintyPreservation"] or 0
                               for row in arm_rows),
                    "denominator": len(arm_rows),
                },
                "readBytes": _measured(arm_rows, "readBytes"),
                "toolCalls": _measured(arm_rows, "toolCalls"),
                "elapsedMs": _measured(arm_rows, "elapsedMs"),
                "consumerCompile": {
                    "compiled": compile_states.get("compiled", 0),
                    "failed": compile_states.get("failed", 0),
                    "missingCode": compile_states.get("missing-code", 0),
                    "notApplicable": compile_states.get("not-applicable", 0),
                    "outstanding": compile_states.get("verification-outstanding", 0),
                    "denominator": len(arm_rows),
                    "unit": "generated consumer",
                },
                "consumerBehavior": {
                    "verified": behavior_states.get("verified", 0),
                    "unverified": behavior_states.get(
                        "runtime-executed-behavior-unverified", 0),
                    "failed": sum(behavior_states.get(state, 0)
                                  for state in BEHAVIOR_FAILURE_STATES),
                    "outstanding": behavior_states.get("verification-outstanding", 0),
                    # Denominator is the behaviorRequired rows only, so a task that
                    # correctly declines code is excluded here and counted under
                    # consumerCompile as not-applicable instead.
                    "denominator": behavior_denominator,
                    "unit": "behaviorRequired consumer",
                },
            },
        }
    missing = [name for name in declare
               if name not in totals[next(iter(totals))]["dimensions"]] if totals else []
    require(not missing, "aggregate is missing rubric dimensions: " + ", ".join(missing))
    return totals


def _measured(rows: list[dict], key: str) -> dict:
    values = [row["dimensions"][key] for row in rows
              if isinstance(row["dimensions"].get(key), (int, float))
              and not isinstance(row["dimensions"][key], bool)]
    unmeasured = [row["task"] for row in rows
                  if not isinstance(row["dimensions"].get(key), (int, float))
                  or isinstance(row["dimensions"].get(key), bool)]
    return {"sum": sum(values), "measuredTasks": len(values),
            "denominator": len(rows), "unmeasured": unmeasured}


# ---------------------------------------------------------------------------
# Report stage
# ---------------------------------------------------------------------------


def successful_process(process: dict | None) -> bool:
    return bool(process and process.get("exitCode") == 0 and
                process.get("timedOut") is False and process.get("launchError") is None)


def validate_process_receipt(process: dict, logs: Path, labels: Labels, where: str) -> None:
    require(isinstance(process, dict), where + ": missing process receipt")
    code = process.get("exitCode")
    require(code is None or type(code) is int, where + ": invalid exit code")
    require(type(process.get("timedOut")) is bool, where + ": missing timeout observation")
    launch = process.get("launchError")
    require(launch is None or isinstance(launch, str) and bool(launch), where + ": invalid launch error")
    require(not launch or code is None and not process["timedOut"], where + ": contradictory launch outcome")
    elapsed = process.get("elapsedMs")
    require(type(elapsed) in (int, float) and elapsed >= 0, where + ": invalid elapsed time")
    for name in ("stdout", "stderr"):
        stream = process.get(name)
        path = logs / name
        require(isinstance(stream, dict) and path.is_file() and not path.is_symlink(),
                where + ": missing captured " + name)
        size = path.stat().st_size
        require(size <= consumer_runtime.FILE_BYTES and type(stream.get("bytes")) is int
                and stream["bytes"] == size, where + ": stream byte count differs")
        require(stream.get("sha256") == consumer_runtime.sha(path), where + ": stream digest differs")
        require(stream.get("path") == labels.text(str(path)), where + ": stream path differs")
        with path.open("rb") as source:
            actual = labels.text(source.read(MAXIMUM_CAPTURED_STREAM_BYTES).decode("utf-8", "replace"))
        require(stream.get("text") == actual, where + ": stream text is not the captured output")
        require(stream.get("truncated") is (size > MAXIMUM_CAPTURED_STREAM_BYTES),
                where + ": stream truncation contradicts its bytes")
    sandbox = process.get("sandbox") or {}
    require(sandbox.get("provider") == "bwrap" and sandbox.get("network") == "unshared"
            and sandbox.get("inheritedEnvironment") is False and sandbox.get("hostHomeMounted") is False
            and sandbox.get("rootReadOnly") is True,
            where + ": process was not executed in the required isolated environment")


def validate_consumer_receipt(item: dict, task: dict, code: str,
                              root: Path, toolchain: dict, labels: Labels) -> None:
    where = task["id"] + ":" + item["arm"]
    expected_hash = digest_text(code)
    require(item.get("consumerCodeSha256") == expected_hash and
            type(item.get("consumerCodeBytes")) is int and item["consumerCodeBytes"] == len(code.encode("utf-8")),
            where + ": receipt consumer bytes differ from the captured raw answer")
    require(item.get("behaviorRequired") is task["behaviorRequired"],
            where + ": receipt changed behaviorRequired")
    scope = item.get("scope") or {}
    require(scope.get("scope") == task.get("scope"), where + ": requested source scope differs from the frozen task")
    require(item.get("integrityFailure") is None, where + ": captured input integrity failed")
    state = item.get("state")
    if code == "":
        expected_state = "missing-code" if task["behaviorRequired"] else "not-applicable"
        require(state == expected_state and item.get("compile") is None and item.get("packaging") is None
                and item.get("behavior") is None,
                where + ": absent consumer code cannot have compiler packaging or runtime evidence")
        return
    require(state in ("pending", "compiled", "compile-failed", "infrastructure-failed"),
            where + ": unsupported non-empty consumer outcome")
    process = item.get("compile")
    if process is None:
        require(state in ("pending", "infrastructure-failed"), where + ": compiled outcome has no compiler receipt")
        if state == "infrastructure-failed":
            require(isinstance(item.get("failure"), dict), where + ": infrastructure failure has no evidence")
        return
    require(scope.get("requestedVersion") == SCOPE_TABLE[task["scope"]].get("requestedVersion")
            and scope.get("locale") == SCOPE_TABLE[task["scope"]].get("locale"),
            where + ": requested version/language differs from the frozen source scope")
    binding = item.get("scopeBinding") or {}
    require(binding.get("state") in ("verified", "unavailable"),
            where + ": compiler receipt has no requested-library binding observation")
    if binding["state"] == "verified":
        require(binding.get("libraryState") in ("built", "not_required") and binding.get("failure") is None,
                where + ": verified library binding contradicts setup evidence")
    else:
        require(binding.get("libraryState") not in ("built", "not_required") and binding.get("failure") is not None
                and isinstance(item.get("failure"), dict),
                where + ": unavailable requested library has no retained failure")
    project = root / "tasks" / task["id"] / item["arm"] / CONSUMER_DIRECTORY
    project_label = labels.text(str(project))
    require(item.get("projectLabel") == project_label, where + ": consumer project identity differs")
    source = project / "input/main.cj"
    require(source.is_file() and not source.is_symlink() and source.read_bytes() == code.encode("utf-8"),
            where + ": executable input was not the exact captured consumerCode")
    packaging = item.get("packaging") or {}
    require(packaging.get("kind") == "verbatim" and packaging.get("prependedBytes") == 0
            and packaging.get("writtenBytes") == len(code.encode("utf-8"))
            and packaging.get("writtenSha256") == expected_hash
            and packaging.get("answerCodeSha256") == expected_hash,
            where + ": compiler input was repaired or its packaging evidence contradicts the capture")
    require(process.get("inputSha256") == expected_hash, where + ": compiler input digest differs")
    command = process.get("command")
    compiler = (toolchain.get("cjc") or {}).get("label")
    prefix = [compiler, "--static", "--output-type", "exe", "-O1",
              "--output-dir", project_label + "/out", "-o", "main"]
    require(isinstance(command, list) and command[:len(prefix)] == prefix
            and command[-1] == project_label + "/input/main.cj"
            and command.count("--output-type") == command.count("--output-dir") == command.count("-o") == 1,
            where + ": receipt does not describe one executable cjc compilation of this program")
    require(process.get("cwd") == project_label + "/scratch/work", where + ": compiler cwd differs")
    validate_process_receipt(process, project / "compile-logs", labels, where + ":compile")
    require(process["sandbox"].get("compilerMounted") is True, where + ": compiler SDK was not isolated")
    compiled = successful_process(process)
    if state == "compiled":
        require(compiled, where + ": compiled outcome contradicts compiler exit, timeout or launch error")
    if state == "compile-failed":
        require(not compiled and process.get("launchError") is None,
                where + ": compile-failed outcome contradicts the observed compiler failure")
    binary = project / "out/main"
    if state == "compiled":
        require(binary.is_file() and not binary.is_symlink() and os.access(binary, os.X_OK),
                where + ": successful compilation has no executable witness")
        with binary.open("rb") as executable:
            require(executable.read(4) == b"\x7fELF", where + ": executable witness is not native ELF")
        require(process.get("binarySha256") == consumer_runtime.sha(binary)
                and process.get("binaryLabel") == project_label + "/out/main",
                where + ": executable witness differs from the compiler receipt")
    behavior = item.get("behavior") or {}
    if behavior.get("state") == "runtime-executed":
        require(state == "compiled" and task["behaviorRequired"] and binding["state"] == "verified",
                where + ": runtime outcome contradicts compilation, source binding or task policy")
        run = behavior.get("run")
        validate_process_receipt(run, project / "run-logs", labels, where + ":run")
        require(run.get("command") == [process["binaryLabel"]]
                and run.get("binarySha256") == process["binarySha256"]
                and run.get("cwd") == project_label + "/run-scratch/work",
                where + ": a different program was executed")
        require(run["sandbox"].get("compilerMounted") is False
                and run["sandbox"].get("newProcessesAllowed") is False
                and run["sandbox"].get("writableFilesystemRoots") is False,
                where + ": generated program did not use the runtime-only read-only sandbox")
    elif behavior.get("state") == "not-required":
        require(state == "compiled" and not task["behaviorRequired"],
                where + ": required behavior was silently marked N/A")
    elif state == "compiled":
        require(isinstance(item.get("failure"), dict)
                and (task["behaviorRequired"] or binding["state"] == "unavailable"),
                where + ": compiled consumer has no runtime policy or retained infrastructure failure")


def load_verification(path: Path, capture: Capture) -> dict:
    receipt = strict_load(path, description="consumer verification")
    require(isinstance(receipt, dict) and receipt.get("schemaVersion") == VERIFICATION_SCHEMA,
            "unsupported consumer verification receipt")
    require((receipt.get("protocol") or {}).get("sha256") == capture.protocol_sha256
            and (receipt.get("rubric") or {}).get("sha256") == capture.rubric_sha256,
            "consumer verification uses different frozen inputs")
    require((receipt.get("run") or {}).get("manifestSha256") == digest_of(capture.manifest_path),
            "consumer verification belongs to a different capture")
    root = path.resolve().parent
    mapping = [(root, "<verification>"), (Path.home(), "$HOME"),
               (Path(tempfile.gettempdir()).resolve(), "$TMPDIR")]
    if os.environ.get("CANGJIE_HOME"):
        mapping.append((Path(os.environ["CANGJIE_HOME"]).resolve(), "<sdk>"))
    labels = Labels(mapping)
    consumers = receipt.get("consumers")
    require(isinstance(consumers, list), "verification has no complete consumer ledger")
    tasks = {task["id"]: task for task in capture.protocol["tasks"]}
    indexed = {}
    for item in consumers:
        require(isinstance(item, dict), "consumer receipt is not an object")
        key = (item.get("task"), item.get("arm"))
        require(key in capture.records and key not in indexed, "unknown or duplicate consumer session")
        record = capture.records[key]
        body = parsed_answer(record, capture.protocol).get("json") or {}
        code = body.get("consumerCode", "")
        code = code if isinstance(code, str) else ""
        cached = (record.get("answer") or {}).get("consumerCode")
        require(cached is None or cached == code, "cached code differs from the captured raw answer")
        validate_consumer_receipt(item, tasks[key[0]], code, root,
                                  receipt.get("toolchain") or {}, labels)
        indexed[key] = item
    require(set(indexed) == set(capture.records), "verification omitted captured task/arm rows")
    require(receipt.get("totals") == consumer_totals(consumers), "verification totals contradict its ledger")
    return {"receipt": receipt, "index": indexed}


def load_adjudication(path: Path, capture: Capture) -> dict:
    document = strict_load(path, description="adjudication")
    require(isinstance(document, dict), "adjudication must be one JSON object")
    require(document.get("schemaVersion") == ADJUDICATION_SCHEMA,
            f"adjudication schemaVersion must be {ADJUDICATION_SCHEMA}")
    require(document.get("protocolSha256") == capture.protocol_sha256,
            "adjudication was written against a different protocol digest")
    require(document.get("rubricSha256") == capture.rubric_sha256,
            "adjudication was written against a different rubric digest")
    assessments = document.get("assessments")
    require(isinstance(assessments, list), "adjudication needs an assessments list")
    return document


def report_stage(args: argparse.Namespace, protocol: dict, rubric: dict,
                 capture: Capture) -> tuple[dict, list[dict]]:
    project_root = Path(os.path.abspath(args.project_root))
    verification_file = Path(os.path.abspath(
        args.verification or capture.output / VERIFICATION_DIRECTORY / VERIFICATION_NAME))
    verification = load_verification(verification_file, capture)
    doc_ir: dict[str, Path] = {}
    for item in args.doc_ir or []:
        label, separator, value = item.partition("=")
        require(bool(separator) and bool(label.strip()) and bool(value.strip()),
                f"--doc-ir requires LABEL=PATH: {item}")
        path = Path(os.path.abspath(value))
        require(path.is_file(), f"--doc-ir file does not exist: {value}")
        doc_ir[label.strip()] = path
    evidence = Evidence(project_root, doc_ir, capture, verification)
    adjudication_path = Path(os.path.abspath(args.adjudications))
    adjudication = load_adjudication(adjudication_path, capture)
    assessments: dict[tuple[str, str], dict] = {}
    for position, item in enumerate(adjudication["assessments"]):
        require(isinstance(item, dict),
                f"adjudication assessments[{position}] must be an object")
        key = (item.get("task"), item.get("arm"))
        require(key[0] in {task["id"] for task in protocol["tasks"]},
                f"adjudication names an unknown task: {key[0]!r}")
        require(key[1] in evaluation.ARMS,
                f"adjudication names an unknown arm: {key[1]!r}")
        require(key not in assessments,
                f"adjudication judges {key[0]}:{key[1]} more than once")
        assessments[key] = item
    rows = []
    gaps: list[dict] = []
    for task in protocol["tasks"]:
        for arm in evaluation.ARMS:
            key = (task["id"], arm)
            receipt = verification["index"].get(key)
            assessment = assessments.get(key)
            record = capture.records[key]
            adjudicated: dict | None = None
            errors: list[str] = []
            if assessment is None:
                errors = [f"{key[0]}:{key[1]}: no adjudication supplied"]
            else:
                behavior = (receipt or {}).get("behavior") or {}
                errors, adjudicated = validate_assessment(
                    assessment, task, arm, record, protocol, behavior, evidence,
                    f"{task['id']}:{arm}")
            prefix = f"{task['id']}:{arm}: "
            for detail in errors:
                # The gap already names the task and arm; keep the message itself
                # free of the repeated location prefix.
                gaps.append({"kind": "adjudication", "task": task["id"],
                             "arm": arm,
                             "detail": detail[len(prefix):]
                             if detail.startswith(prefix) else detail})
            row = row_for(capture, task, arm, receipt, assessment, errors,
                          adjudicated, protocol)
            if row["consumer"]["compile"] == "verification-outstanding":
                gaps.append({"kind": "consumer-verification", "task": task["id"],
                             "arm": arm,
                             "detail": "no compile receipt for this consumer"})
            if task["behaviorRequired"] and \
                    row["dimensions"]["consumerBehavior"] == \
                    "runtime-executed-behavior-unverified":
                gaps.append({"kind": "consumer-behavior", "task": task["id"],
                             "arm": arm,
                             "detail": "consumer executed but no boundary assertion "
                                       "was adjudicated"})
            elif task["behaviorRequired"] and \
                    row["dimensions"]["consumerBehavior"] == \
                    "verification-outstanding":
                gaps.append({"kind": "consumer-behavior", "task": task["id"],
                             "arm": arm,
                             "detail": "consumer behavior was never verified"})
            rows.append(row)
    evidence.check_current_inputs()
    totals = aggregate(rows, protocol, rubric)
    registered_roots = [(verification_file.parent, "<verification>"),
        (capture.output, "<output>"), (project_root, "<repo>"),
        (Path(tempfile.gettempdir()).resolve(), "$TMPDIR"), (Path.home(), "$HOME")]
    sdk_root = os.environ.get("CANGJIE_HOME")
    if sdk_root:
        registered_roots.append((Path(sdk_root).resolve(), "<sdk>"))
    for label, source in doc_ir.items():
        registered_roots.append((source, "<doc-ir:" + label + ">"))
    labels = Labels(registered_roots)
    # Only a gap-free report may be published as a completed adjudication.
    report = {
        "schemaVersion": REPORT_SCHEMA,
        "status": "final" if not gaps else "incomplete",
        "claim": rubric.get("claim"),
        "denominator": rubric.get("taskDenominator"),
        "budgets": capture.budgets,
        "arms": list(evaluation.ARMS),
        "taskOrder": protocol["comparison"]["taskOrder"],
        "inputs": {
            "protocol": {"path": evaluation.repo_relative(args.protocol),
                         "sha256": capture.protocol_sha256},
            "rubric": {"path": evaluation.repo_relative(args.rubric),
                       "sha256": capture.rubric_sha256},
            "run": {"label": "<output>",
                    "manifestSha256": digest_of(capture.manifest_path),
                    "records": len(capture.records)},
            "verification": {"label": "<verification>/" + VERIFICATION_NAME,
                             "sha256": digest_of(verification_file),
                             "toolchain": verification["receipt"].get("toolchain"),
                             "scopes": verification["receipt"].get("scopes")},
            "adjudication": {"sha256": digest_of(adjudication_path),
                             "docIr": [{"label": label, "sha256": digest_of(path)}
                                       for label, path in sorted(doc_ir.items())]},
        },
        "completeness": {
            "frozenTasks": len(protocol["tasks"]),
            "frozenArms": len(evaluation.ARMS),
            "expectedRuns": len(protocol["tasks"]) * len(evaluation.ARMS),
            "observedRuns": len(rows),
            "completePair": len(rows) == len(protocol["tasks"]) * len(evaluation.ARMS),
            "repetitionsPerTaskPerPath": 1,
            "adjudicatedAssessments": sum(1 for row in rows
                                          if row["adjudication"]["state"] == "complete"),
            "outstandingGaps": len(gaps),
        },
        "selection": {"bestOf": False, "retries": 0, "budgetRelaxation": False,
                      "retainedFailures": [row["task"] + ":" + row["arm"]
                                           for row in rows
                                           if row["model"]["outcome"] == "failed"
                                           or row["dimensions"]["consumerCompile"]
                                           in COMPILE_FAILURE_STATES],
                      "policy": "every captured failure, budget overrun and failed "
                                "consumer remains in the report"},
        "records": rows,
        "totals": totals,
        "scoring": {
            "state": "adjudicated" if not gaps else "incomplete",
            "dimensions": list(protocol["scoreDimensions"]),
            "naturalLanguageScoring": "no keyword scoring: every requiredFact verdict "
                                      "is supplied with a verbatim answer quote and "
                                      "source/Doc IR evidence",
            "measuredDimensions": ["readBytes", "toolCalls", "elapsedMs", "consumerCompile"],
            "behaviorJudgment": "captured runtime plus an explicit manual source/control-flow audit; neither stdout nor exit zero alone is proof",
            "adjudicatedDimensions": list(ADJUDICATED_DIMENSIONS) + ["contractOmissions"],
        },
        "gaps": gaps,
        "privacy": {"labels": sorted({label for _, label in registered_roots}),
                    "policy": "registered capture, verification, source, SDK, temporary and home roots are normalized; raw-byte hashes refer to private original inputs",
                    "sourceAudit": "manual review and the publication privacy gate remain required for other identifiers"},
    }
    scrubbed = labels.scrub(report)
    forbidden = [str(source) for source, _ in registered_roots]
    leaks = privacy_violations(scrubbed, forbidden)
    require(not leaks, "refusing a report that leaks local paths: " + "; ".join(leaks[:5]))
    return scrubbed, gaps


def observations_stage(capture: Capture, verification_file: Path | None,
                       protocol: dict) -> dict:
    verification = None
    if verification_file is not None:
        verification = load_verification(verification_file, capture)["index"]
    rows = []
    for task in protocol["tasks"]:
        for arm in evaluation.ARMS:
            record = capture.records[(task["id"], arm)]
            classification = evaluation.classify(record)
            answer = record.get("answer") or {}
            receipt = (verification or {}).get((task["id"], arm))
            rows.append({
                "task": task["id"],
                "arm": arm,
                "outcome": classification["taskOutcome"],
                "causes": classification["causes"],
                "budgetFailure": classification["budgetFailure"],
                "answerPresent": bool(answer.get("present")),
                "consumerCodeBytes": len((answer.get("consumerCode") or "").encode()),
                "toolCalls": (record.get("toolUse") or {}).get("calls"),
                "resultBytes": (record.get("toolUse") or {}).get("resultBytes"),
                "elapsedMs": ((record.get("client") or {}).get("process") or {})
                .get("elapsedMs"),
                "consumerCompile": consumer_compile_state(receipt, task, record),
                "consumerBehavior": consumer_behavior_state(task, record, receipt, None),
                "adjudication": "unadjudicated",
            })
    return {
        "schemaVersion": OBSERVATION_SCHEMA,
        "status": "observations",
        "claim": "one complete paired observation; no score is assigned here",
        "capturedRun": {"manifestSha256": digest_of(capture.manifest_path),
                        "records": len(capture.records)},
        "budgets": capture.budgets,
        "records": rows,
        "scoring": {"state": "unadjudicated",
                    "reason": "observations contain measured and compiler-verified "
                              "facts only; requiredFacts, citations and API identity "
                              "judgments come from a separate adjudication"},
    }


def template_stage(capture: Capture, protocol: dict) -> dict:
    assessments = []
    for task in protocol["tasks"]:
        for arm in evaluation.ARMS:
            record = capture.records[(task["id"], arm)]
            citations = answer_citations(record, protocol)
            code = (parsed_answer(record, protocol).get("json") or {}).get("consumerCode", "")
            code = code if isinstance(code, str) else ""
            assessments.append({
                "task": task["id"],
                "arm": arm,
                "scope": task.get("scope"),
                "behaviorRequired": task["behaviorRequired"],
                "capturedAnswer": (record.get("answer") or {}).get("raw"),
                "requiredFacts": [{"fact": fact, "verdict": "", "answerQuote": "",
                                   "evidence": []}
                                  for fact in task["requiredFacts"]],
                "citations": [{"index": index, "citation": citation,
                               "verdict": "", "evidence": []}
                              for index, citation in enumerate(citations)],
                "dimensions": {name: {"value": None, "evidence": [], "note": ""}
                               for name in ADJUDICATED_DIMENSIONS},
                "behaviorAssertions": [],
                "behaviorReview": {"method": "manual-source-and-control-flow-audit",
                    "consumerCodeSha256": digest_text(code),
                    "verdict": "unverified", "coversTaskBoundaries": False,
                    "codeQuote": "", "reason": ""} if task["behaviorRequired"] else None,
            })
    return {
        "schemaVersion": ADJUDICATION_SCHEMA,
        "status": "template",
        "protocolSha256": capture.protocol_sha256,
        "rubricSha256": capture.rubric_sha256,
        "note": "Fill every verdict with source/Doc IR evidence and a verbatim "
                "answerQuote; this template scores nothing.",
        "assessments": assessments,
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Compile, run and adjudicate the frozen paired Agent evaluation.",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    def common(subparser: argparse.ArgumentParser) -> None:
        subparser.add_argument("--output", required=True, type=Path,
                               help="captured evaluator output directory")
        subparser.add_argument("--protocol", default=PROTOCOL, type=Path)
        subparser.add_argument("--rubric", default=RUBRIC, type=Path)
        subparser.add_argument("--project-root", default=REPO, type=Path,
                               help="checkout containing the frozen scope sources")

    verify = subparsers.add_parser(
        "verify", help="compile and run every generated consumer once")
    common(verify)
    verify.add_argument("--verification", type=Path,
                        help="verification directory (default <output>/verification)")
    verify.add_argument("--sdk-root", type=Path,
                        help="installed Cangjie SDK root; sets CANGJIE_HOME")
    verify.add_argument("--compile-seconds", type=int, default=DEFAULT_COMPILE_SECONDS)
    verify.add_argument("--run-seconds", type=int, default=DEFAULT_RUN_SECONDS)

    report = subparsers.add_parser(
        "report", help="combine capture, verification and adjudication")
    common(report)
    report.add_argument("--verification", type=Path,
                        help="verification receipt "
                             "(default <output>/verification/verification.json)")
    report.add_argument("--adjudications", required=True, type=Path)
    report.add_argument("--doc-ir", action="append", default=[], metavar="LABEL=PATH")
    report.add_argument("--final", type=Path,
                        help="final report path (default <output>/final-report.json)")
    report.add_argument("--observations", type=Path,
                        help="also write explicit observations next to the report")

    observe = subparsers.add_parser(
        "observations", help="publish measured facts without any score")
    common(observe)
    observe.add_argument("--verification", type=Path)
    observe.add_argument("--out", type=Path)

    template = subparsers.add_parser(
        "template", help="write an empty adjudication skeleton for reviewers")
    common(template)
    template.add_argument("--out", required=True, type=Path)
    return parser


def _capture(args: argparse.Namespace) -> tuple[dict, dict, Capture]:
    protocol_path = Path(os.path.abspath(args.protocol))
    rubric_path = Path(os.path.abspath(args.rubric))
    protocol, rubric = load_frozen(protocol_path, rubric_path)
    capture = Capture(Path(args.output), protocol, rubric, protocol_path, rubric_path)
    return protocol, rubric, capture


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    try:
        protocol, rubric, capture = _capture(args)
        if args.command == "verify":
            result = verify_stage(args, protocol, rubric, capture)
            print(result["path"])
            return 0
        if args.command == "observations":
            verification_file = (Path(os.path.abspath(args.verification))
                                 if args.verification else None)
            observations = observations_stage(capture, verification_file, protocol)
            destination = Path(os.path.abspath(args.out)) if args.out else \
                capture.output / "observations.json"
            evaluation.write_json(destination, observations)
            print(destination)
            return 0
        if args.command == "template":
            destination = Path(os.path.abspath(args.out))
            evaluation.write_json(destination, template_stage(capture, protocol))
            print(destination)
            return 0
        report, gaps = report_stage(args, protocol, rubric, capture)
        destination = (Path(os.path.abspath(args.final)) if args.final
                       else capture.output / "final-report.json")
        if args.observations:
            # Observations are measurable with or without a final report.
            verification_file = Path(os.path.abspath(
                args.verification or capture.output / VERIFICATION_DIRECTORY
                / VERIFICATION_NAME))
            evaluation.write_json(
                Path(os.path.abspath(args.observations)),
                labels_scrub(observations_stage(capture, verification_file,
                                                protocol), capture))
        if gaps:
            for gap in gaps:
                print(f"gap {gap['kind']} {gap['task']}:{gap['arm']}: {gap['detail']}",
                      file=sys.stderr)
            print(f"error: refusing a final report with {len(gaps)} outstanding "
                  f"items; supply complete source-backed assessments", file=sys.stderr)
            return 3
        evaluation.write_json(destination, report)
        print(destination)
        return 0
    except ProofError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


def labels_scrub(value: Any, capture: Capture) -> Any:
    return Labels([(capture.output, "<output>"), (Path.home(), "$HOME")]).scrub(value)


if __name__ == "__main__":
    raise SystemExit(main())
