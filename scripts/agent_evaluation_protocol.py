"""Validate frozen Agent evaluation inputs and select the exact sessions to run."""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import stat
from pathlib import Path

if __package__:
    from .strict_json import strict_load
else:
    from strict_json import strict_load

PROTOCOL_LOADER_PATH = Path(__file__).resolve()
REPO = PROTOCOL_LOADER_PATH.parent.parent
FACT_PROTOCOL = REPO / "tests/agent/evaluation-protocol.json"
DEFAULT_PROTOCOL = REPO / "tests/agent/evaluation-client-transport-v2.json"
DEFAULT_RUBRIC = REPO / "tests/agent/evaluation-rubric.json"
ARMS = ("baseline-html-index", "shared-query-mcp")


def digest_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()



class ProtocolError(ValueError):
    """The frozen protocol or rubric cannot be used as-is."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ProtocolError(message)


def _expand_client_transport(protocol: dict) -> dict:
    if protocol.get("schemaVersion") == "cjdoc.agent-evaluation-protocol/1":
        return protocol
    _require(protocol.get("schemaVersion") == "cjdoc.agent-evaluation-protocol/2",
             "unsupported protocol schemaVersion")
    allowed = {"schemaVersion", "status", "factProtocol", "clientTransport",
               "supersedesObservation"}
    _require(not set(protocol) - allowed,
             "transport protocol cannot override frozen tasks, budgets or client settings")
    _require(protocol.get("clientTransport") == "codex-0.163-mcp-host",
             "unsupported documentation-only client transport")
    reference = protocol.get("factProtocol")
    _require(isinstance(reference, dict) and set(reference) == {"path", "sha256"} and
             reference["path"] == FACT_PROTOCOL.name,
             "transport protocol must reference the original frozen factual protocol")
    _require(digest_of(FACT_PROTOCOL) == reference["sha256"],
             "original factual protocol digest differs")
    facts = strict_load(FACT_PROTOCOL, description="original frozen factual protocol")
    _require(isinstance(facts, dict) and
             facts.get("schemaVersion") == "cjdoc.agent-evaluation-protocol/1",
             "transport protocol requires the original factual protocol version")
    expanded = dict(facts)
    expanded.update(protocol)
    return expanded


def load_protocol(path: Path) -> dict:
    protocol = strict_load(path, description="evaluation protocol")
    _require(isinstance(protocol, dict), "protocol must be an object")
    protocol = _expand_client_transport(protocol)
    comparison = protocol.get("comparison") or {}
    _require(list(comparison.get("paths") or []) == list(ARMS),
             f"protocol paths must be exactly {list(ARMS)}")
    _require(comparison.get("repetitionsPerTaskPerPath") == 1,
             "protocol must require exactly one repetition per task and path")
    _require(comparison.get("keepAllFailures") is True, "protocol must keep all failures")
    _require(comparison.get("stableImprovementClaimAllowed") is False,
             "protocol must not allow a stable-improvement claim")
    tasks = protocol.get("tasks")
    _require(isinstance(tasks, list) and len(tasks) == 12, "protocol must freeze 12 tasks")
    identifiers = [task.get("id") for task in tasks]
    _require(len(set(identifiers)) == 12 and all(identifiers), "task ids must be unique")
    _require(identifiers == sorted(identifiers), "protocol task order must be id-ascending")
    for task in tasks:
        _require(isinstance(task.get("prompt"), str) and task["prompt"].strip(),
                 f"task {task.get('id')} has no prompt")
        _require(isinstance(task.get("requiredFacts"), list),
                 f"task {task.get('id')} has no requiredFacts")
        _require(isinstance(task.get("behaviorRequired"), bool),
                 f"task {task.get('id')} has no behaviorRequired flag")
    budgets = protocol.get("budgets") or {}
    _require(budgets.get("budgetFailureIsTaskFailure") is True,
             "protocol must treat a budget failure as a task failure")
    for key in ("maximumToolCallsPerTask", "maximumDocumentBytesPerTask",
                "maximumSecondsPerTask"):
        _require(isinstance(budgets.get(key), int) and budgets[key] > 0,
                 f"protocol budget {key} must be a positive integer")
    _require(isinstance(protocol.get("answerFields"), list) and protocol["answerFields"],
             "protocol must freeze the answer fields")
    return protocol


def load_rubric(path: Path, protocol: dict) -> dict:
    rubric = strict_load(path, description="evaluation rubric")
    _require(isinstance(rubric, dict), "rubric must be an object")
    _require(rubric.get("schemaVersion") == "cjdoc.agent-evaluation-rubric/1",
             "unsupported rubric schemaVersion")
    dimensions = rubric.get("dimensions")
    _require(isinstance(dimensions, dict), "rubric must define dimensions")
    missing = [name for name in protocol["scoreDimensions"] if name not in dimensions]
    _require(not missing, f"rubric is missing dimensions: {missing}")
    _require(rubric.get("aggregation", {}).get("noBestOfSelection") is True,
             "rubric must forbid best-of selection")
    return rubric


def plan_runs(protocol: dict) -> list[dict]:
    """One client session per task and arm, path order alternating by ordinal."""
    runs = []
    for ordinal, task in enumerate(protocol["tasks"], start=1):
        order = ARMS if ordinal % 2 == 1 else tuple(reversed(ARMS))
        for position, arm in enumerate(order):
            runs.append({"ordinal": ordinal, "task": task, "arm": arm,
                         "armPosition": position})
    return runs


# Only these published representations are reachable from the baseline arm. Doc IR
# (`docs.json`), api-surface, coverage and quality reports are oracle material and
# must not be reachable through a shell inside the captured tree either.
PUBLISHED_TEXT_NAMES = frozenset({"llms.txt", "llms-full.txt", "navigation-index.json",
                                  "symbol-index.json", "search-index.json",
                                  "site-manifest.json", "version.json"})
PUBLISHED_SUFFIXES = (".html", ".md")
BASELINE_VIEW_DIRECTORY = "_baseline-view"


def published_document(name: str) -> bool:
    return name in PUBLISHED_TEXT_NAMES or name.endswith(PUBLISHED_SUFFIXES)


def prepare_baseline_view(source: Path, destination: Path) -> dict:
    """Copy only published documentation into a per-run, oracle-free view.

    The captured tree also stores Doc IR and analysis reports next to the site.
    Only published representations enter this view; explicitly named MCP sites
    are the complete allowlist, and neither evaluation arm has a shell tool.
    """
    if destination.exists():
        raise SystemExit(f"error: baseline view already exists: {destination}")
    copied = 0
    total_bytes = 0
    for base, directories, files in os.walk(source, followlinks=False):
        directories[:] = sorted(name for name in directories if name != ".git")
        for name in sorted(files):
            if not published_document(name):
                continue
            origin = Path(base) / name
            if origin.is_symlink() or not origin.is_file():
                continue
            relative = origin.relative_to(source)
            target = destination / relative
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            try:
                os.link(origin, target)
            except OSError:
                shutil.copyfile(origin, target)
            copied += 1
            total_bytes += target.stat().st_size
    if copied == 0:
        raise SystemExit(f"error: baseline tree publishes no usable documentation: {source}")
    return {"documents": copied, "bytes": total_bytes,
            "kinds": ["llms", "navigation-index", "symbol-index", "search-index",
                      "site-manifest", "rendered page", "markdown page"]}


class RunOptions:
    """Everything one evaluation invocation needs, validated once."""

    def __init__(self, args: argparse.Namespace, protocol: dict, rubric: dict) -> None:
        self.protocol = protocol
        self.rubric = rubric
        self.binary = _executable(args.binary, "--binary")
        self.codex = args.codex
        self.baseline = _directory(args.baseline, "--baseline") if args.baseline else None
        self.baseline_sites = _baseline_sites(args.site, self.baseline)
        self.snapshots = [_regular(path, "--snapshot") for path in args.snapshot]
        self.output = Path(os.path.abspath(args.output))
        self.budgets = dict(protocol["budgets"])
        self.budgets.update({
            "maximumToolCallsPerTask": _bounded(args.max_tool_calls,
                                                protocol["budgets"]["maximumToolCallsPerTask"],
                                                "--max-tool-calls"),
            "maximumDocumentBytesPerTask": _bounded(
                args.max_document_bytes,
                protocol["budgets"]["maximumDocumentBytesPerTask"], "--max-document-bytes"),
            "maximumSecondsPerTask": _bounded(args.max_seconds,
                                              protocol["budgets"]["maximumSecondsPerTask"],
                                              "--max-seconds"),
        })
        self.arms = tuple(args.arm) if args.arm else ARMS
        self.tasks = tuple(args.task) if args.task else None
        self.dry_run = args.dry_run
        self.placeholders = None
        # The baseline arm is pointed at a per-run published-only view; the capture
        # itself stays untouched and private.
        self.baseline_view = (self.output / BASELINE_VIEW_DIRECTORY) if self.baseline else None

    def selected(self) -> list[dict]:
        known = {task["id"] for task in self.protocol["tasks"]}
        unknown = sorted(set(self.tasks or ()) - known)
        if unknown:
            raise SystemExit(f"error: unknown task ids: {', '.join(unknown)}")
        return [run for run in plan_runs(self.protocol)
                if run["arm"] in self.arms
                and (self.tasks is None or run["task"]["id"] in self.tasks)]

    def validate_arms(self) -> None:
        if "shared-query-mcp" in self.arms and not self.snapshots:
            raise SystemExit("error: the shared-query-mcp arm needs at least one --snapshot")
        if "baseline-html-index" in self.arms:
            if self.baseline is None:
                raise SystemExit("error: the baseline-html-index arm needs --baseline")
            if not self.baseline_sites:
                raise SystemExit("error: the baseline-html-index arm needs at least one "
                                 "--site NAME=RELATIVE_PATH to name the allowed sites")
        for snapshot in self.snapshots:
            if snapshot.suffix != ".json" and not snapshot.is_dir():
                raise SystemExit(f"error: --snapshot must be a docs.json or a directory: {snapshot}")


def _executable(path: Path, option: str) -> Path:
    resolved = Path(os.path.abspath(path))
    try:
        metadata = resolved.stat()
    except OSError as error:
        raise SystemExit(f"error: {option} does not exist: {path}") from error
    if not stat.S_ISREG(metadata.st_mode) or not os.access(resolved, os.X_OK):
        raise SystemExit(f"error: {option} must be an executable regular file: {path}")
    return resolved


def _regular(path: Path, option: str) -> Path:
    resolved = Path(os.path.abspath(path))
    if not resolved.is_file():
        raise SystemExit(f"error: {option} must be an existing file: {path}")
    return resolved


def _baseline_sites(values: list[str], root: Path | None) -> list[tuple[str, Path]]:
    """Name the captured sites the baseline server may publish: NAME=RELATIVE_PATH."""
    sites: list[tuple[str, Path]] = []
    names: set[str] = set()
    for value in values:
        name, separator, relative = value.partition("=")
        if not separator or not name.strip() or not relative.strip():
            raise SystemExit(f"error: --site requires NAME=RELATIVE_PATH: {value}")
        name = name.strip()
        path = Path(relative.strip())
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"error: --site path must stay inside the captured tree: {value}")
        if name in names:
            raise SystemExit(f"error: duplicate --site name: {name}")
        if root is not None:
            candidate = root / path
            if not (candidate / "navigation-index.json").is_file():
                raise SystemExit(f"error: --site {name} is not a captured site with "
                                 f"navigation-index.json: {candidate}")
        names.add(name)
        sites.append((name, path))
    return sites


def arm_site_arguments(options: "RunOptions") -> list[str]:
    """The --site arguments the baseline server receives, pointing at the view."""
    arguments: list[str] = []
    for name, relative in options.baseline_sites:
        arguments.extend(["--site", f"{name}={options.baseline_view / relative}"])
    return arguments


def _directory(path: Path, option: str) -> Path:
    resolved = Path(os.path.abspath(path))
    if not resolved.is_dir():
        raise SystemExit(f"error: {option} must be an existing directory: {path}")
    return resolved


def _bounded(requested: int | None, frozen: int, option: str) -> int:
    if requested is None:
        return frozen
    if requested < 1 or requested > frozen:
        raise SystemExit(f"error: {option} may only tighten the frozen budget {frozen}")
    return requested
