"""Validate frozen Agent evaluation inputs and select the exact sessions to run."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import stat
import sys
from pathlib import Path

if __package__:
    from .strict_json import strict_load
else:
    from strict_json import strict_load

PROTOCOL_LOADER_PATH = Path(__file__).resolve()
REPO = PROTOCOL_LOADER_PATH.parent.parent
# The corrected protocol pins current source citations without changing the
# historical factual protocol, task prompts, or grading rules.
FACT_PROTOCOL = REPO / "tests/agent/evaluation-protocol-v2.json"
HISTORICAL_PROTOCOL = REPO / "tests/agent/evaluation-protocol.json"
DEFAULT_PROTOCOL = REPO / "tests/agent/evaluation-client-transport-v3.json"
DEFAULT_RUBRIC = REPO / "tests/agent/evaluation-rubric.json"
ARMS = ("baseline-html-index", "shared-query-mcp")

# The rubric also contains answer/evidence requirements (e.g. keep the same
# snapshot during continuation) that are not literals in a Cangjie source file.
# Use exact source excerpts to bind each citation to the API it actually names.
# Every witness must occur inside one contiguous cited span: separate ranges or
# files cannot be spliced into a body or an example the source never shows.


def _lines(*lines: str) -> str:
    """Join archived source lines verbatim; the guard never reflows them."""
    return "\n".join(lines)


INTEGER_ADD = "public func add(value: Int64, radix!: Int64 = 10): Unit {"
RADIX_GUARD = 'if (radix != 10) { throw IllegalArgumentException("only decimal radix is supported") }'
INTEGER_APPEND = "values.add(value.toString())"
# Complete declarations and examples: a partial fenced block, an unterminated
# loop or a missing expected-output fence cannot satisfy a full-body citation.
INTEGER_BODY = _lines(
    INTEGER_ADD,
    "        " + RADIX_GUARD,
    "        " + INTEGER_APPEND,
    "    }",
)
STRING_ADD = "public func add(value: String): Unit { values.add(value) }"
STRING_ADD_EXAMPLE = _lines(
    "     * @example[lang=en] Keep an empty entry {run}",
    "     * ```cangjie",
    "     * let catalog = TextCatalog()",
    '     * catalog.add("")',
    '     * println("count: ${catalog.size}")',
    '     * println("bytes: ${catalog.at(0).size}")',
    "     * ```",
    "     *",
    "     * **Expected output**",
    "     *",
    "     * ```output",
    "     * count: 1",
    "     * bytes: 0",
    "     * ```",
)
WINDOW_BODY = _lines(
    "public func window(start!: Int64 = 0, limit!: Int64 = 20): Array<?String> {",
    '        if (start < 0 || start > values.size || limit < 0) { throw IllegalArgumentException("invalid window") }',
    "        let output = ArrayList<?String>()",
    "        var index = start",
    "        while (index < values.size && output.size < limit) {",
    "            output.add(Some(values[index]))",
    "            index++",
    "        }",
    "        output.toArray()",
    "    }",
)
WINDOW_EXAMPLE = _lines(
    # The start/limit example with its setup, loop body, terminator and output.
    "     * @example 按位置与上限取窗口 {run}",
    "     * ```cangjie",
    '     * let catalog = TextCatalog(["a", "b", "c", "d"])',
    "     * ```",
    "     * ```cangjie",
    "     * let page = catalog.window(start: 1, limit: 2)",
    "     * for (entry in page) {",
    "     *     println(entry.getOrThrow())",
    "     * }",
    "     * ```",
    "     *",
    "     * **预期输出 / Expected output**",
    "     *",
    "     * ```output",
    "     * b",
    "     * c",
    "     * ```",
)
WINDOW_EXAMPLE_DEFAULTS = _lines(
    "     * @example 默认参数与末尾短窗口 {run}",
    "     * ```cangjie",
    '     * let catalog = TextCatalog(["a", "b", "c"])',
    '     * println("default length: ${catalog.window().size}")',
    '     * println("tail length: ${catalog.window(start: 2).size}")',
    "     * ```",
    "     *",
    "     * **预期输出 / Expected output**",
    "     *",
    "     * ```output",
    "     * default length: 3",
    "     * tail length: 1",
    "     * ```",
)
WINDOW_EXAMPLE_EMPTY = _lines(
    "     * @example 三种空窗口 {run}",
    "     * ```cangjie",
    '     * let catalog = TextCatalog(["a", "b", "c"])',
    '     * println("at end: ${catalog.window(start: catalog.size).size}")',
    '     * println("zero limit: ${catalog.window(limit: 0).size}")',
    '     * println("empty catalogue: ${TextCatalog().window().size}")',
    "     * ```",
    "     *",
    "     * **预期输出 / Expected output**",
    "     *",
    "     * ```output",
    "     * at end: 0",
    "     * zero limit: 0",
    "     * empty catalogue: 0",
    "     * ```",
)
WINDOW_EXAMPLE_INVALID = _lines(
    "     * @example 越界参数抛出异常 {run}",
    "     * ```cangjie",
    '     * let catalog = TextCatalog(["a"])',
    "     * for ((start, limit) in [(-1, 1), (catalog.size + 1, 1), (0, -1)]) {",
    "     *     try {",
    "     *         catalog.window(start: start, limit: limit)",
    '     *         throw IllegalStateException("expected an invalid window")',
    "     *     } catch (_: IllegalArgumentException) {",
    '     *         println("start=${start}, limit=${limit}: IllegalArgumentException")',
    "     *     }",
    "     * }",
    "     * ```",
    "     *",
    "     * **预期输出 / Expected output**",
    "     *",
    "     * ```output",
    "     * start=-1, limit=1: IllegalArgumentException",
    "     * start=2, limit=1: IllegalArgumentException",
    "     * start=0, limit=-1: IllegalArgumentException",
    "     * ```",
)
# The window contract names the empty-start boundary directly; its examples are
# only evidence when each fenced block and its expected output is whole.
WINDOW_WITNESSES = (
    WINDOW_BODY,
    WINDOW_EXAMPLE,
    WINDOW_EXAMPLE_DEFAULTS,
    WINDOW_EXAMPLE_EMPTY,
    WINDOW_EXAMPLE_INVALID,
    "start == size` returns an empty window",
)
# AG-11's continuation question resolves to the String overload (with the code
# block it must not truncate) and the window retry path, not the full contract.
RETRY_WITNESSES = (
    STRING_ADD,
    STRING_ADD_EXAMPLE,
    INTEGER_BODY,
    WINDOW_BODY,
    WINDOW_EXAMPLE,
)
BLOCK_WITNESSES = {
    STRING_ADD: "complete String overload declaration",
    STRING_ADD_EXAMPLE: "complete String overload example with its expected output",
    INTEGER_BODY: "complete integer overload body",
    WINDOW_BODY: "complete window declaration body",
    WINDOW_EXAMPLE: "complete start/limit example with its expected output",
    WINDOW_EXAMPLE_DEFAULTS: "complete default-parameter example with its expected output",
    WINDOW_EXAMPLE_EMPTY: "complete empty-window example with its expected output",
    WINDOW_EXAMPLE_INVALID: "complete invalid-argument example with its expected output",
}
SOURCE_WITNESSES = {
    "AG-01": ("value: Int64", "radix!: Int64 = 10", INTEGER_BODY,
              RADIX_GUARD, INTEGER_APPEND),
    "AG-02": ('version = "0.1.0"', "public func add(value: Int64): Unit { values.add(value.toString()) }"),
    "AG-03": WINDOW_WITNESSES,
    "AG-04": ("At EOF, `read()` returns `None` and the session stays open.",
              "没有文件描述符、网络连接或后台线程需要销毁", "不提供内部同步",
              'public func read(): ?String {\n        if (isClosed) { throw IllegalStateException("reader is closed") }',
              'public func rewind(): Unit {\n        if (isClosed) { throw IllegalStateException("reader is closed") }',
              "public func close(): Unit { isClosed = true }"),
    "AG-05": ("public class Entry<T>", "extend Entry<String>", "UTF-8 字节数，而不是 Unicode 标量数",
              "public func byteLength(): Int64 { value.size }"),
    "AG-06": ("@since 0.2.0", "public func nonEmpty(): Array<String>", 'version = "0.1.0"'),
    "AG-07": ("Instances do not synchronize access internally.", "首条文本；空目录返回 None",
              "public func first(): ?String { tryAt(0) }"),
    "AG-08": ("public import reexport_dep.make as create",
              "public import acme::reexport_dep.make as orgCreate", "public import reexport_dep.conflict.*"),
    "AG-09": ('default-language = "zh-CN"', "原样追加一组条目", "public func addAll(entries: Array<String>): Unit"),
    "AG-10": ("macro package unsupported_fixture", "public macro Echo(input: Tokens)"),
    "AG-11": RETRY_WITNESSES,
    "AG-12": ("@see pocket_support.SourceLabel.text", "本地标签 / Local stamp",
              "package pocket_support", "public struct SourceLabel {\n    /** 原样保存的标签文本。 */\n    public let text",
              "外部 Stamp。与 pocketkit.Stamp 同名，但身份和文档集不同。"),
}


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
    fact_paths = {path.name: path for path in (HISTORICAL_PROTOCOL, FACT_PROTOCOL)}
    _require(isinstance(reference, dict) and set(reference) == {"path", "sha256"} and
             isinstance(reference["path"], str) and reference["path"] in fact_paths,
             "transport protocol must reference a frozen factual protocol")
    fact_path = fact_paths[reference["path"]]
    _require(digest_of(fact_path) == reference["sha256"],
             "frozen factual protocol digest differs")
    facts = strict_load(fact_path, description="frozen factual protocol")
    _require(isinstance(facts, dict) and
             facts.get("schemaVersion") == "cjdoc.agent-evaluation-protocol/1",
             "transport protocol requires the factual protocol schema")
    if fact_path == FACT_PROTOCOL:
        _require(bool(facts.get("sourceCitationBaseline")),
                 "corrected factual protocol lacks its frozen source baseline")
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


def source_slices(reference: str, project_root: Path) -> list[dict]:
    """Split a frozen `source` reference into file/directory and line-range parts.

    A `source` value is `path[:LINE[-LINE][,LINE[-LINE]]]` entries joined by `;`.
    Only the range is interpreted; a missing file or range is reported, not repaired.
    """
    parts: list[dict] = []
    for piece in str(reference or "").split(";"):
        piece = piece.strip()
        if not piece:
            continue
        match = re.fullmatch(r"(?P<path>[^:]+)(?::(?P<range>[\d,\-]+))?", piece)
        if match is None:
            raise ProtocolError(f"unparsable frozen source reference: {piece!r}")
        path = project_root / match.group("path")
        item = {"reference": match.group("path"), "path": path, "range": None}
        if match.group("range"):
            ranges = []
            for span in match.group("range").split(","):
                bounds = span.split("-")
                if len(bounds) == 1:
                    start = end = int(bounds[0])
                elif len(bounds) == 2:
                    start, end = int(bounds[0]), int(bounds[1])
                else:
                    raise ProtocolError(f"unparsable frozen source range: {piece!r}")
                if start < 1 or end < start:
                    raise ProtocolError(f"invalid frozen source range: {piece!r}")
                ranges.append((start, end))
            item["range"] = ranges
        parts.append(item)
    return parts


def _read_source(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""


def source_spans(item: dict, text: str | None = None) -> list[str]:
    """Each cited range as its own contiguous text; ranges are never joined."""
    lines = (_read_source(item["path"]) if text is None else text).splitlines()
    if item["range"] is None:
        return ["\n".join(lines)]
    spans: list[str] = []
    for start, end in item["range"]:
        if end > len(lines):
            return []
        spans.append("\n".join(lines[start - 1:end]))
    return spans


def source_text(item: dict, text: str | None = None) -> str:
    """The selected lines of a file, or the whole file if no range is given."""
    return "\n".join(source_spans(item, text))


def verify_source_slices(protocol: dict, project_root: Path,
                         task_ids: tuple[str, ...] = tuple(SOURCE_WITNESSES)) -> None:
    """Resolve each active citation and fail when it misses its source evidence.

    Evidence is accepted only inside one contiguous cited span. Listing the
    separate lines that happen to hold the expected fragments cannot prove a
    declaration body or an example block the source never cites whole.
    """
    tasks = {task.get("id"): task for task in protocol.get("tasks") or []}
    baseline = protocol.get("sourceCitationBaseline")
    pinned = None
    if baseline is not None:
        _require(isinstance(baseline, dict) and
                 isinstance(baseline.get("revision"), str) and
                 bool(re.fullmatch(r"[0-9a-f]{40}", baseline["revision"])) and
                 isinstance(baseline.get("utf8TextSha256"), dict),
                 "malformed frozen source citation baseline")
        pinned = baseline["utf8TextSha256"]
    observed: dict[str, str] = {}
    for identifier in task_ids:
        task = tasks.get(identifier)
        _require(task is not None, f"protocol does not freeze task {identifier}")
        parts = source_slices(str(task.get("source") or ""), project_root)
        _require(bool(parts), f"{identifier}: no frozen source citation")
        spans: list[str] = []
        for item in parts:
            name = item["reference"]
            if name not in observed:
                text = _read_source(item["path"])
                if pinned is not None:
                    # read_text normalizes checked-out CRLF to the archived LF.
                    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
                    _require(pinned.get(name) == digest,
                             f"{identifier}: {name!r} differs from the frozen source citation baseline")
                observed[name] = text
            selected = source_spans(item, observed[name])
            _require(bool(selected) and all(selected),
                     f"{identifier}: cannot read cited source slice {name!r}")
            spans.extend(selected)
        fragments = SOURCE_WITNESSES[identifier]
        if identifier == "AG-01":
            # Report a swapped radix guard before the body-completeness witness.
            for span in spans:
                if INTEGER_ADD in span and RADIX_GUARD in span and INTEGER_APPEND in span:
                    _require(span.index(RADIX_GUARD) < span.index(INTEGER_APPEND),
                             f"{identifier}: invalid radix check no longer precedes append")
                    break
            fragments += tuple(task["requiredFacts"])
        for fragment in fragments:
            first_line = fragment.splitlines()[0]
            description = BLOCK_WITNESSES.get(fragment)
            detail = f" ({description})" if description else ""
            _require(any(fragment in span for span in spans),
                     f"{identifier}: source slice no longer contains {first_line!r}{detail}")


def verify_sources(protocol_path: Path = DEFAULT_PROTOCOL,
                   project_root: Path = REPO) -> dict:
    """Load a frozen protocol and prove its pinned source slices still hold."""
    protocol = load_protocol(protocol_path)
    verify_source_slices(protocol, project_root)
    return protocol


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate the frozen Agent evaluation protocol and its source slices.")
    parser.add_argument("--protocol", type=Path, default=DEFAULT_PROTOCOL)
    parser.add_argument("--project-root", type=Path, default=REPO)
    arguments = parser.parse_args(argv)
    try:
        protocol = verify_sources(arguments.protocol, arguments.project_root)
    except ProtocolError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"verified source citations for {len(protocol['tasks'])} frozen tasks")
    return 0


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


if __name__ == "__main__":
    sys.exit(main())
