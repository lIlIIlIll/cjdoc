#!/usr/bin/env python3
"""Run the frozen paired Agent evaluation against real client and server processes.

Two arms consume the same captured v16 documentation, and both reach it the same
way: one real MCP stdio server behind one recording, budgeting relay, with every
non-document client tool disabled.

* `baseline-html-index` -- `agent_baseline_mcp.py` publishes only the captured
  pre-change static site's llms text, machine indexes and rendered pages. The run
  gets its own published-only view, and only explicitly named sites are served.
* `shared-query-mcp`    -- the native `cjdoc mcp --snapshot ...` server.

Nothing here scores a model. The runner records what actually happened: the
client's own JSONL events, the last structured answer, and every JSON-RPC line
that crossed each arm's transport (definitions, requests, results, sizes,
timings). Budgets are fixed by `tests/agent/evaluation-protocol.json`, every
failure is retained, and no task is retried. Compilation and behavioral
adjudication belong to the parent's real compiler run; this tool only marks
where they are still outstanding.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any

sys.dont_write_bytecode = True
try:
    from .strict_json import strict_dumps, strict_load
except ImportError:  # Direct script execution.
    from strict_json import strict_dumps, strict_load

REPO = Path(__file__).resolve().parent.parent
FACT_PROTOCOL = REPO / "tests/agent/evaluation-protocol.json"
DEFAULT_PROTOCOL = REPO / "tests/agent/evaluation-client-transport-v2.json"
DEFAULT_RUBRIC = REPO / "tests/agent/evaluation-rubric.json"
ARMS = ("baseline-html-index", "shared-query-mcp")
MCP_SERVER_NAME = "cjdoc"
RELAY_LOG_NAME = "mcp-stdio.jsonl"
SERVER_STDERR_NAME = "server.stderr.log"
CLIENT_LOG_NAME = "client.jsonl"
CLIENT_STDERR_NAME = "client.stderr.log"
LAST_MESSAGE_NAME = "last-message.json"
RECORD_NAME = "record.json"
REPORT_NAME = "report.json"
MANIFEST_NAME = "run-manifest.json"
RELENDING_ARGUMENT = "--snapshot"
ENFORCEMENT_ERROR = "budget-exceeded"
SERVER_SHUTDOWN_SECONDS = 10
GROUP_GRACE_SECONDS = 0.3
MCP_STARTUP_SECONDS = 120


def digest_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.write_text(strict_dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def repo_relative(path: Path) -> str:
    """Describe a path inside this repository relative to it, else by label."""
    try:
        return Path(os.path.abspath(path)).relative_to(REPO).as_posix()
    except ValueError:
        return "<external>"


def compact(value: Any) -> str:
    return strict_dumps(value, ensure_ascii=False, separators=(",", ":"))


# ---------------------------------------------------------------------------
# Frozen inputs
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# Placeholders keep public records portable
# ---------------------------------------------------------------------------


class Placeholders:
    """Replace machine-specific absolute roots with stable labels."""

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
            return {key: self.scrub(item) for key, item in value.items()}
        return value

    def command(self, argv: list[str]) -> list[str]:
        return [self.text(item) for item in argv]


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


# ---------------------------------------------------------------------------
# MCP stdio relay: a real forwarding proxy that records and enforces budgets
# ---------------------------------------------------------------------------


class RelayBudget:
    """Fixed per-task limits, applied to what actually crosses stdio."""

    def __init__(self, max_tool_calls: int, max_result_bytes: int) -> None:
        self.max_tool_calls = max_tool_calls
        self.max_result_bytes = max_result_bytes
        self.tool_calls = 0
        self.result_bytes = 0
        self.exceeded: str | None = None

    def refuse_call(self, ordinal: int) -> str | None:
        """Refuse a call that may not start: budget failures are never retried."""
        if self.exceeded == "toolCalls" or ordinal > self.max_tool_calls:
            self.exceeded = self.exceeded or "toolCalls"
            return (f"tool call budget exhausted: {self.max_tool_calls} attempted calls per task; "
                    "further calls are refused")
        if self.exceeded == "documentBytes":
            return (f"document byte budget exhausted: {self.result_bytes} of "
                    f"{self.max_result_bytes} bytes already delivered; further calls are refused")
        return None

    def admit_result(self, result_bytes: int) -> str | None:
        """Check one intact result before delivery; refusal notices are also measured.

        Once exhausted, no further document payload is admitted. A small failure
        notice can itself cross the limit; the task stays failed and its actual
        delivered cost must not disappear from the ledger.
        """
        if self.result_bytes + result_bytes > self.max_result_bytes:
            self.exceeded = self.exceeded or "documentBytes"
            return (f"document byte budget exhausted: {self.result_bytes} of "
                    f"{self.max_result_bytes} bytes already delivered; this "
                    f"{result_bytes}-byte result was not returned")
        return None


def _decode_line(line: bytes) -> dict | None:
    try:
        parsed = json.loads(line)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    return parsed if isinstance(parsed, dict) else None


def _tool_call_name(parsed: dict) -> str | None:
    if parsed.get("method") != "tools/call" or "id" not in parsed:
        return None
    params = parsed.get("params")
    name = params.get("name") if isinstance(params, dict) else None
    return name if isinstance(name, str) else ""


def _result_bytes(line: bytes, field: str = "result") -> int:
    """Exact UTF-8 bytes of the transmitted top-level result/error JSON value."""
    text = line.decode("utf-8")
    decoder = json.JSONDecoder()
    index = 0

    def whitespace(position: int) -> int:
        while position < len(text) and text[position] in " \t\r\n":
            position += 1
        return position

    index = whitespace(index)
    if index >= len(text) or text[index] != "{":
        raise ValueError("MCP response is not an object")
    index = whitespace(index + 1)
    size = 0
    while index < len(text) and text[index] != "}":
        key, index = decoder.raw_decode(text, index)
        index = whitespace(index)
        if text[index] != ":":
            raise ValueError("MCP response member has no value")
        start = whitespace(index + 1)
        _, index = decoder.raw_decode(text, start)
        if key == field:
            size = len(text[start:index].encode("utf-8"))
        index = whitespace(index)
        if text[index] == ",":
            index = whitespace(index + 1)
        elif text[index] != "}":
            raise ValueError("MCP response members are not separated")
    return size


def _budget_response(request_id: Any, message: str) -> bytes:
    body = {"error": ENFORCEMENT_ERROR, "message": message}
    response = {"jsonrpc": "2.0", "id": request_id,
                "result": {"content": [{"type": "text", "text": compact(body)}],
                           "isError": True}}
    return (compact(response) + "\n").encode("utf-8")


class Relay:
    """Forward one MCP stdio session verbatim while recording and budgeting it."""

    def __init__(self, child: subprocess.Popen, log: Any, budget: RelayBudget) -> None:
        self.child = child
        self.log = log
        self.budget = budget
        self.lock = threading.Lock()
        self.write_lock = threading.Lock()
        self.pending: dict[Any, tuple[str, float]] = {}
        self.calls: list[dict] = []

    def record(self, direction: str, line: bytes, parsed: dict | None,
               refusal: str | None = None, **extra: Any) -> None:
        entry: dict[str, Any] = {
            "direction": direction,
            "bytes": len(line),
            "monotonicMs": round(time.perf_counter() * 1000, 3),
            "line": line.decode("utf-8", "replace").rstrip("\n"),
        }
        if parsed is None:
            entry["parsed"] = "non-json"
        else:
            entry["id"] = parsed.get("id")
            method = parsed.get("method")
            if isinstance(method, str):
                entry["method"] = method
            else:
                entry["ok"] = "result" in parsed
                if isinstance(parsed.get("error"), dict):
                    entry["error"] = parsed["error"]
        if refusal is not None:
            entry["budgetRefusal"] = refusal
        entry.update(extra)
        self.log.write(compact(entry) + "\n")
        self.log.flush()

    def deliver(self, line: bytes, parsed: dict | None, refusal: str | None = None,
                **extra: Any) -> None:
        with self.write_lock:
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
            self.budget.result_bytes += int(extra.get("resultBytes") or 0)
            self.record("server->client", line, parsed, refusal, **extra)

    def client_lines(self) -> None:
        try:
            for line in sys.stdin.buffer:
                parsed = _decode_line(line)
                name = _tool_call_name(parsed) if parsed is not None else None
                if name is not None:
                    with self.lock:
                        self.budget.tool_calls += 1
                        ordinal = self.budget.tool_calls
                        refusal = self.budget.refuse_call(ordinal)
                        if refusal is None:
                            self.pending[parsed["id"]] = (name, time.perf_counter())
                        self.record("client->server", line, parsed, refusal,
                                    tool=name, ordinal=ordinal)
                        if refusal is not None:
                            response = _budget_response(parsed["id"], refusal)
                            self.deliver(response, _decode_line(response), refusal,
                                         tool=name, resultBytes=_result_bytes(response))
                            continue
                else:
                    self.record("client->server", line, parsed)
                assert self.child.stdin is not None
                try:
                    self.child.stdin.write(line)
                    self.child.stdin.flush()
                except (BrokenPipeError, ValueError):
                    break
        finally:
            try:
                if self.child.stdin is not None:
                    self.child.stdin.close()
            except (BrokenPipeError, ValueError):
                pass

    def server_lines(self) -> None:
        assert self.child.stdout is not None
        for line in self.child.stdout:
            parsed = _decode_line(line)
            with self.lock:
                if parsed is None or parsed.get("id") not in self.pending:
                    self.deliver(line, parsed)
                    continue
                name, issued = self.pending.pop(parsed["id"])
                duration_ms = round((time.perf_counter() - issued) * 1000, 3)
                result_bytes = _result_bytes(line, "result" if "result" in parsed else "error")
                refusal = self.budget.admit_result(result_bytes)
                if refusal is not None:
                    response = _budget_response(parsed["id"], refusal)
                    self.deliver(response, _decode_line(response), refusal,
                                 tool=name, callMs=duration_ms,
                                 resultBytes=_result_bytes(response),
                                 withheldResultBytes=result_bytes)
                    continue
                self.deliver(line, parsed, tool=name, callMs=duration_ms,
                             resultBytes=result_bytes)

    def run(self) -> int:
        server = threading.Thread(target=self.server_lines, daemon=True)
        server.start()
        self.client_lines()
        # The client is gone, so the server must reach EOF; a server that ignores
        # the closed stdin is stopped here rather than left running.
        server.join(timeout=SERVER_SHUTDOWN_SECONDS)
        if server.is_alive():
            _terminate_server(self.child)
            server.join(timeout=SERVER_SHUTDOWN_SECONDS)
        with self.lock:
            self.log.write(compact({"kind": "budget", "toolCalls": self.budget.tool_calls,
                                    "resultBytes": self.budget.result_bytes,
                                    "exceeded": self.budget.exceeded}) + "\n")
            self.log.flush()
        return 0


def relay_main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="agent_evaluation.py relay",
                                     description="Forward MCP stdio, recording and budgeting")
    parser.add_argument("--log", required=True, type=Path, help="JSONL transcript directory")
    parser.add_argument("--max-tool-calls", required=True, type=int)
    parser.add_argument("--max-result-bytes", required=True, type=int)
    parser.add_argument("--cwd", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER,
                        help="-- then the real stdio server command")
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("relay requires a server command after --")
    args.log.mkdir(mode=0o700, parents=True, exist_ok=True)
    budget = RelayBudget(args.max_tool_calls, args.max_result_bytes)
    stderr_path = args.log / SERVER_STDERR_NAME
    with stderr_path.open("wb") as errors, \
            (args.log / RELAY_LOG_NAME).open("w", encoding="utf-8") as log:
        child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=errors, cwd=args.cwd)
        try:
            return Relay(child, log, budget).run()
        finally:
            _terminate_server(child)

def _terminate_server(process: subprocess.Popen) -> None:
    # Servers stay in the client's group so the task deadline cannot orphan a
    # separately-sessioned MCP process. Normal EOF stops only this server.
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
    process.wait()


def _terminate_group(process: subprocess.Popen) -> None:
    try:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        if process.poll() is None:
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
    finally:
        # A reaped leader does not imply its process group has exited.
        _kill(process)
        process.wait()


def _tool_definitions(parsed: dict) -> list[dict] | None:
    """Tool names and input schemas from one tools/list result, if that is what it is."""
    result = parsed.get("result")
    tools = result.get("tools") if isinstance(result, dict) else None
    if not isinstance(tools, list):
        return None
    return [{"name": tool.get("name"), "description": tool.get("description"),
             "inputSchema": tool.get("inputSchema"), "annotations": tool.get("annotations")}
            for tool in tools if isinstance(tool, dict)]


def read_relay_log(path: Path) -> dict:
    """Recompute transport facts, definitions, requests and results from the transcript."""
    if not path.is_file():
        return {"available": False}
    summary: dict[str, Any] = {
        "available": True, "initialize": 0, "toolsList": 0, "toolCalls": 0,
        "toolNames": [], "toolDefinitions": None, "advertisedTools": [],
        "toolRequests": [], "toolResults": [], "resultBytes": 0,
        "transportBytes": {"clientToServer": 0, "serverToClient": 0},
        "responses": 0, "errors": 0, "protocolVersion": None, "serverInfo": None,
        "budget": None, "malformedLines": 0, "budgetRefusals": 0,
        "receiptSizesConsistent": True,
        "withheldResults": 0, "callMs": [], "callMsTotal": 0.0,
    }
    for raw in path.read_text(encoding="utf-8").splitlines():
        try:
            item = json.loads(raw)
        except json.JSONDecodeError:
            summary["malformedLines"] += 1
            continue
        if not isinstance(item, dict):
            summary["malformedLines"] += 1
            continue
        if item.get("kind") == "budget":
            summary["budget"] = {key: item.get(key) for key in
                                 ("toolCalls", "resultBytes", "exceeded")}
            continue
        direction = item.get("direction")
        if direction not in ("client->server", "server->client"):
            summary["malformedLines"] += 1
            continue
        key = "clientToServer" if direction == "client->server" else "serverToClient"
        summary["transportBytes"][key] += int(item.get("bytes") or 0)
        if item.get("budgetRefusal") is not None and direction == "client->server":
            # One refused attempt produces both a request record and the synthesized
            # response; count the attempt once.
            summary["budgetRefusals"] += 1
        method = item.get("method")
        if method == "initialize":
            summary["initialize"] += 1
        elif method == "tools/list":
            summary["toolsList"] += 1
        elif method == "tools/call":
            summary["toolCalls"] += 1
        if direction == "client->server" and method == "tools/call":
            summary["toolRequests"].append({"id": item.get("id"), "tool": item.get("tool"),
                                            "arguments": _arguments_of(item)})
        if direction == "server->client" and "ok" in item:
            parsed = _safe_loads(item.get("line"))
            if parsed is not None and isinstance(parsed.get("result"), dict):
                definitions = _tool_definitions(parsed)
                if definitions is not None:
                    summary["toolDefinitions"] = definitions
                    summary["advertisedTools"] = [tool["name"] for tool in definitions]
                initialized = parsed["result"]
                if "protocolVersion" in initialized:
                    summary["protocolVersion"] = initialized.get("protocolVersion")
                    summary["serverInfo"] = initialized.get("serverInfo")
        if isinstance(item.get("tool"), str) and direction == "server->client":
            summary["toolNames"].append(item["tool"])
            entry = {"tool": item["tool"], "id": item.get("id"),
                     "callMs": item.get("callMs"), "withheld": False}
            parsed = _safe_loads(item.get("line"))
            if parsed is not None and ("result" in parsed or "error" in parsed):
                field = "result" if "result" in parsed else "error"
                actual_bytes = _result_bytes(item["line"].encode("utf-8"), field)
                summary["resultBytes"] += actual_bytes
                entry["resultBytes"] = actual_bytes
                entry["ok"] = item.get("ok")
                if type(item.get("resultBytes")) is not int or item["resultBytes"] != actual_bytes:
                    summary["receiptSizesConsistent"] = False
            else:
                summary["receiptSizesConsistent"] = False
            if item.get("withheldResultBytes") is not None:
                summary["withheldResults"] += 1
                entry.update(withheld=True, withheldResultBytes=item["withheldResultBytes"],
                             reason=item.get("budgetRefusal"))
            summary["toolResults"].append(entry)
            if isinstance(item.get("callMs"), (int, float)):
                summary["callMsTotal"] = round(summary["callMsTotal"] + item["callMs"], 3)
                summary["callMs"].append(item["callMs"])
        if "ok" in item:
            summary["responses"] += 1
            if item.get("ok") is False:
                summary["errors"] += 1
    requested = sorted((compact(item["id"]), item["tool"])
                       for item in summary["toolRequests"])
    delivered = sorted((compact(item["id"]), item["tool"])
                       for item in summary["toolResults"])
    # Codex can kill its MCP subprocess instead of closing stdin. A complete
    # request/delivery journal still proves the exact transmitted result spans;
    # an in-flight, malformed or mismatched receipt must remain unknown.
    journal_complete = (
        bool(summary["protocolVersion"]) and isinstance(summary["serverInfo"], dict)
        and summary["toolDefinitions"] is not None
        and not summary["malformedLines"] and summary["receiptSizesConsistent"]
        and requested == delivered)
    summary["deliveryJournalComplete"] = journal_complete
    summary["totalsRecorded"] = summary["budget"] is not None
    if summary["budget"] is None:
        summary["totalsSource"] = "complete-delivery-journal" if journal_complete else "unknown"
        if not journal_complete:
            summary["resultBytes"] = None
    else:
        summary["totalsSource"] = "closing-budget"
        # Compare the closing counters with independent raw-wire span counts.
        summary["totalsConsistent"] = (
            summary["receiptSizesConsistent"] and not summary["malformedLines"]
            and int(summary["budget"].get("toolCalls") or 0) == summary["toolCalls"]
            and int(summary["budget"].get("resultBytes") or 0) == summary["resultBytes"])
    return summary


def _arguments_of(item: dict) -> Any:
    parsed = _safe_loads(item.get("line"))
    params = parsed.get("params") if isinstance(parsed, dict) else None
    return params.get("arguments") if isinstance(params, dict) else None


def _safe_loads(value: Any) -> dict | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


# ---------------------------------------------------------------------------
# Client invocation
# ---------------------------------------------------------------------------


def measured_process(command: list[str], stdout: Path, stderr: Path, timeout: float,
                     cwd: Path | None = None) -> dict:
    """Run one process group under a hard deadline and kill what it leaves behind."""
    if os.name != "posix":
        raise ValueError("the evaluation runner requires POSIX process-group control")
    expired = threading.Event()
    started = time.perf_counter()
    with stdout.open("wb") as output, stderr.open("wb") as errors:
        process = subprocess.Popen(command, stdout=output, stderr=errors, cwd=cwd,
                                   start_new_session=True)
        timer = threading.Timer(timeout, lambda: (expired.set(), _kill(process)))
        timer.daemon = True
        timer.start()
        try:
            process.wait()
            # The client's MCP child is in this group and may still be flushing its
            # own transcript; give it a bounded grace period, then stop the group.
            time.sleep(GROUP_GRACE_SECONDS)
        finally:
            timer.cancel()
            timer.join()
            _terminate_group(process)
    return {"exitCode": process.returncode, "timedOut": expired.is_set(),
            "elapsedMs": round((time.perf_counter() - started) * 1000, 3)}


def _kill(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def toml_array(values: list[str]) -> str:
    return "[" + ", ".join(toml_string(value) for value in values) + "]"


# Both arms use documentation servers behind the same stdio relay; content tools
# remain disabled. Codex 0.163 also needs code_mode_host for MCP discovery/dispatch
# even with code_mode disabled. Replay v1 unchanged; v2 fixes only that transport
# prerequisite and the native loader environment, never the frozen task oracle.
DISABLED_FEATURES = (
    "shell_tool", "unified_exec", "apps", "browser_use", "browser_use_external",
    "computer_use", "in_app_browser", "code_mode", "code_mode_host", "plugins",
    "memories", "multi_agent", "multi_agent_v2", "skill_search", "view_image",
    "image_generation",
)
NATIVE_RUNTIME_ENVIRONMENT = ("PATH", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH",
                              "DYLD_FALLBACK_LIBRARY_PATH", "cjHeapSize")


def client_feature_policy(protocol: dict) -> tuple[tuple[str, ...], tuple[str, ...]]:
    enabled = (("code_mode_host",) if
               protocol["schemaVersion"] == "cjdoc.agent-evaluation-protocol/2" else ())
    disabled = tuple(feature for feature in DISABLED_FEATURES if feature not in enabled)
    return disabled, enabled

BASELINE_SERVER = Path(__file__).resolve().parent / "agent_baseline_mcp.py"
BASELINE_SERVER_KIND = "captured-published-docs"
NATIVE_SERVER_KIND = "native-cjdoc-mcp"
# The tools each documentation server must actually advertise. A session that
# never contacts its server, or contacts one without these tools, has not
# performed the arm under evaluation.
BASELINE_TOOLS = ("list_documents", "read_document")
NATIVE_TOOLS = ("resolve_docs", "search", "get_symbol")


def codex_command(options: "RunOptions", session: Path, prompt: str,
                  server: dict) -> list[str]:
    """The complete client invocation for one task and arm."""
    client = options.protocol["client"]
    command = [options.codex, "exec", "--json",
               "--output-last-message", str(session / LAST_MESSAGE_NAME),
               "--cd", str(session), "--skip-git-repo-check",
               "--ephemeral", "--sandbox", client.get("sandbox", "read-only"),
               "--model", client["requestedModel"],
               "-c", f"model_reasoning_effort={toml_string(client['reasoningEffort'])}",
               "-c", f"project_doc_max_bytes={int(client['projectDocMaxBytes'])}",
               # Top-level `web_search` is the setting this client accepts; the
               # `tools.web_search` name is not the documented surface.
               "-c", 'web_search="disabled"',
               # No approval prompt can be answered in a non-interactive run, and a
               # read-only sandbox plus one explicit server leaves nothing to approve.
               "-c", 'approval_policy="never"']
    if client.get("ignoreUserConfig", True):
        command.append("--ignore-user-config")
    disabled, enabled = client_feature_policy(options.protocol)
    for feature in disabled:
        command.extend(["--disable", feature])
    for feature in enabled:
        command.extend(["--enable", feature])
    prefix = f"mcp_servers.{MCP_SERVER_NAME}."
    command.extend([
        "-c", f"{prefix}command={toml_string(server['command'][0])}",
        "-c", f"{prefix}args={toml_array(server['command'][1:])}",
        "-c", f"{prefix}cwd={toml_string(str(session))}",
        "-c", f"{prefix}enabled=true",
        "-c", f"{prefix}startup_timeout_sec={int(server['startupTimeoutSec'])}",
        "-c", f"{prefix}tool_timeout_sec={int(server['toolTimeoutSec'])}",
    ])
    if options.protocol["schemaVersion"] == "cjdoc.agent-evaluation-protocol/2":
        command.extend(["-c", f"{prefix}required=true"])
    for name, value in sorted(server.get("env", {}).items()):
        command.extend(["-c", f"{prefix}env.{name}={toml_string(value)}"])
    command.append(prompt)
    return command


def relay_launch(options: "RunOptions", session: Path, log_dir: Path,
                 native: list[str]) -> dict:
    """Wrap one real documentation server in the recording, budgeting relay."""
    relay = [sys.executable, str(Path(__file__).resolve()), "relay",
             "--log", str(log_dir),
             "--max-tool-calls", str(options.budgets["maximumToolCallsPerTask"]),
             "--max-result-bytes", str(options.budgets["maximumDocumentBytesPerTask"]),
             "--cwd", str(session), "--", *native]
    return {"command": relay, "nativeCommand": native,
            "startupTimeoutSec": MCP_STARTUP_SECONDS,
            "toolTimeoutSec": options.budgets["maximumSecondsPerTask"]}


def arm_server(options: "RunOptions", session: Path, arm: str) -> dict:
    """The real MCP server this arm documents itself through, behind the relay."""
    if arm == "baseline-html-index":
        native = [sys.executable, str(BASELINE_SERVER), "--baseline",
                  str(options.baseline_view), *arm_site_arguments(options)]
        server = relay_launch(options, session, session, native)
        server["kind"] = BASELINE_SERVER_KIND
        server["expectedTools"] = list(BASELINE_TOOLS)
    else:
        # The shared tool contract is a single `cjdoc mcp` process that loads every
        # snapshot; repeating --snapshot is how more than one document set is named.
        native = [str(options.binary), "mcp"]
        for snapshot in options.snapshots:
            native.extend([RELENDING_ARGUMENT, str(snapshot)])
        server = relay_launch(options, session, session, native)
        server["kind"] = NATIVE_SERVER_KIND
        server["expectedTools"] = list(NATIVE_TOOLS)
        if options.protocol["schemaVersion"] == "cjdoc.agent-evaluation-protocol/2":
            server["env"] = {name: os.environ[name] for name in NATIVE_RUNTIME_ENVIRONMENT
                             if name in os.environ and (name != "PATH" or os.name == "nt")}
    return server


def answer_contract(protocol: dict) -> str:
    fields = protocol["answerFields"]
    listed = ", ".join(f'"{name}"' for name in fields)
    return (
        "Answer contract: your final message MUST be one JSON object with exactly these keys: "
        f"{listed}. `apiChoices` and `citations` are arrays of objects with the fields you "
        "actually verified; `facts`, `selectedScopes` and `caveats` are arrays of strings; "
        "`consumerCode` is a single Cangjie source string, or \"\" when no consumer is "
        "justified. Every citation must name the document you read and the exact scope "
        "(site, version, language, symbol id) as the tools reported it. Never invent "
        "signatures, source lines or translations. Do not write files."
    )


def task_prompt(protocol: dict, run: dict, arm: str, baseline: Path | None) -> str:
    """The exact user message for one task and arm; nothing else is supplied."""
    task = run["task"]
    scope = task.get("scope") or ""
    lines = [
        f"Task {task['id']}. Documentation scope under evaluation: {scope}.",
        "",
        task["prompt"],
        "",
        answer_contract(protocol),
    ]
    if arm == "baseline-html-index":
        lines.extend([
            "",
            "Available documentation: the baseline MCP server, which publishes only the "
            "captured pre-change static site. Start with tools/list, then list_documents to "
            "enumerate its sites, languages and files (llms.txt, llms-full.txt, "
            "navigation-index.json, symbol-index.json, search-index.json, site-manifest.json, "
            "rendered HTML/Markdown pages), and read_document to read byte windows of exactly "
            "those files. There is no filesystem, shell or web access in this environment: "
            "everything must come from the server. Doc IR, api-surface/coverage reports and "
            "repository source are not published; when the published documentation does not "
            "establish a fact, keep it unknown rather than reconstructing it from the library "
            "name or a different version.",
        ])
    else:
        lines.extend([
            "",
            "Available documentation: the shared query MCP server. Start with tools/list, "
            "then resolve_docs, search and get_symbol with the same request fields the public "
            "core uses (without `operation`). Every response names its snapshot and scope; "
            "keep that scope when you continue or retry a read. There is no filesystem, shell "
            "or web access in this environment.",
        ])
    return "\n".join(lines)


def summarize_client_events(events: list[dict]) -> dict:
    """Read the client's own JSONL: usage, server tools and the last agent message.

    Shell execution is recorded only as evidence: both arms run with the shell
    disabled, so any command here means the environment did not honour that.
    """
    summary = {"events": len(events), "threadId": None, "usage": None,
               "toolCalls": 0, "toolNames": [], "commandExecutions": 0,
               "commandOutputBytes": 0, "lastAgentMessage": None,
               "failedTurns": 0, "errors": [], "eventTypes": {}}
    for event in events:
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        if isinstance(kind, str):
            summary["eventTypes"][kind] = summary["eventTypes"].get(kind, 0) + 1
        if kind == "thread.started":
            summary["threadId"] = event.get("thread_id")
        elif kind == "turn.completed":
            summary["usage"] = event.get("usage")
        elif kind == "turn.failed":
            summary["failedTurns"] += 1
            summary["errors"].append("turn.failed")
        elif kind == "error":
            summary["errors"].append(str(event.get("message"))[:200])
        item = event.get("item")
        if not isinstance(item, dict):
            continue
        item_type = item.get("type")
        if item_type == "mcp_tool_call":
            summary["toolCalls"] += 1
            summary["toolNames"].append(item.get("tool"))
        elif item_type == "command_execution":
            # The shell is disabled for both arms, so this is a contract breach to
            # report, never a normal way to reach documentation.
            summary["toolCalls"] += 1
            summary["commandExecutions"] += 1
            output = item.get("aggregated_output")
            if isinstance(output, str):
                summary["commandOutputBytes"] += len(output.encode("utf-8"))
        elif item_type == "agent_message" and isinstance(item.get("text"), str):
            summary["lastAgentMessage"] = item["text"]
    return summary


def parse_answer(text: str | None, fields: list[str]) -> dict:
    """Extract the last structured answer; never repair or invent fields."""
    answer = {"present": False, "json": None, "missingFields": list(fields),
              "extraFields": [], "parseError": None}
    if not isinstance(text, str) or not text.strip():
        answer["parseError"] = "client produced no final message"
        return answer
    candidates = []
    stripped = text.strip()
    if stripped.startswith("{") and stripped.endswith("}"):
        candidates.append(stripped)
    if "```" in text:
        for block in text.split("```")[1::2]:
            block = block.strip()
            if block.startswith("json"):
                block = block[4:].strip()
            if block.startswith("{"):
                candidates.append(block)
    for candidate in candidates:
        try:
            parsed = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            answer["json"] = parsed
            break
    if answer["json"] is None:
        answer["parseError"] = "final message is not a JSON object"
        return answer
    present = answer["json"]
    answer["present"] = True
    answer["missingFields"] = [name for name in fields if name not in present]
    answer["extraFields"] = [name for name in present if name not in fields]
    return answer


# ---------------------------------------------------------------------------
# Task execution
# ---------------------------------------------------------------------------


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


def run_one(options: RunOptions, run: dict, session: Path) -> dict:
    """Execute exactly one client session; never retried, never reselected."""
    task = run["task"]
    arm = run["arm"]
    session.mkdir(mode=0o700, parents=True, exist_ok=False)
    server = arm_server(options, session, arm)
    prompt = task_prompt(options.protocol, run, arm,
                         options.baseline_view if arm == "baseline-html-index"
                         else options.baseline)
    command = codex_command(options, session, prompt, server)
    process = measured_process(command, session / CLIENT_LOG_NAME,
                               session / CLIENT_STDERR_NAME,
                               timeout=options.budgets["maximumSecondsPerTask"],
                               cwd=session)
    events = read_client_events(session / CLIENT_LOG_NAME)
    summary = summarize_client_events(events)
    transport = read_relay_log(session / RELAY_LOG_NAME)
    if transport.get("available"):
        # The relay sees every JSON-RPC line, so it, not the client's event log,
        # is the authority for attempted calls and delivered result bytes.
        summary["toolCalls"] = transport["toolCalls"]
        result_bytes = transport["resultBytes"]
    else:
        result_bytes = None
    contact = server_contact(transport, server["expectedTools"])
    last_message_path = session / LAST_MESSAGE_NAME
    last_message = (last_message_path.read_text(encoding="utf-8", errors="replace")
                    if last_message_path.is_file() else None)
    if last_message is None:
        last_message = summary["lastAgentMessage"]
    answer = parse_answer(last_message, options.protocol["answerFields"])
    budget = dict(options.budgets)
    failures: list[dict] = []
    breaches: list[dict] = []
    if summary["commandExecutions"]:
        breaches.append({"kind": "clientCommandExecution",
                         "rule": "shell disabled for both arms",
                         "observed": summary["commandExecutions"]})
    if summary["toolCalls"] > budget["maximumToolCallsPerTask"]:
        failures.append({"kind": "toolCalls", "limit": budget["maximumToolCallsPerTask"],
                         "observed": summary["toolCalls"]})
    if result_bytes is None:
        # In-flight or incomplete receipts cannot prove the delivered byte total;
        # that is a measurement gap, not evidence of a budget breach.
        measurement_gaps = ["documentBytesUnknown"]
    else:
        measurement_gaps = []
        if result_bytes > budget["maximumDocumentBytesPerTask"]:
            failures.append({"kind": "documentBytes",
                             "limit": budget["maximumDocumentBytesPerTask"],
                             "observed": result_bytes})
    if transport.get("totalsConsistent") is False or transport.get("receiptSizesConsistent") is False:
        measurement_gaps.append("inconsistentRelayCounters")
    relay_budget = transport.get("budget") or {}
    if relay_budget.get("exceeded") or transport.get("budgetRefusals") or transport.get("withheldResults"):
        failures.append({"kind": "relayRefusal", "limit": relay_budget.get("exceeded", "recorded-refusal"),
                         "observed": {"toolCalls": relay_budget.get("toolCalls"),
                                      "resultBytes": relay_budget.get("resultBytes"),
                                      "refusals": transport.get("budgetRefusals"),
                                      "withheld": transport.get("withheldResults")}})
    if process["timedOut"]:
        failures.append({"kind": "seconds", "limit": budget["maximumSecondsPerTask"],
                         "observed": process["elapsedMs"]})
    record = {
        "schemaVersion": "cjdoc.agent-evaluation-record/1",
        "task": {"id": task["id"], "scope": task.get("scope"),
                 "behaviorRequired": task["behaviorRequired"],
                 "requiredFacts": task["requiredFacts"], "prompt": task["prompt"]},
        "arm": arm,
        "ordinal": run["ordinal"],
        "armPosition": run["armPosition"],
        "session": {"relativeToOutput": session.relative_to(options.output).as_posix(),
                    "freshSession": True,
                    "prompt": options.placeholders.scrub(prompt),
                    "serverKind": server["kind"],
                    "server": options.placeholders.scrub(server["nativeCommand"]),
                    "serverCommand": options.placeholders.command(server["command"]),
                    "expectedTools": server["expectedTools"],
                    "runtimeEnvironment": options.placeholders.scrub(server.get("env", {}))},
        "client": {
            "command": options.placeholders.command(command),
            "process": process,
            "threadId": summary["threadId"],
            "usage": summary["usage"],
            "failedTurns": summary["failedTurns"],
            "errors": options.placeholders.scrub(summary["errors"]),
            "eventTypes": summary["eventTypes"],
        },
        "toolUse": {
            "serverContact": contact,
            "calls": summary["toolCalls"],
            "clientToolNames": summary["toolNames"],
            "commandExecutions": summary["commandExecutions"],
            "definitions": transport.get("toolDefinitions"),
            "requests": options.placeholders.scrub(transport.get("toolRequests")),
            "results": transport.get("toolResults"),
            "resultBytes": result_bytes,
            "measurement": ("sum of serialized tools/call result JSON delivered over stdio, "
                            "never deduplicated; the relay enforces the fixed limits"),
            "transport": options.placeholders.scrub(transport),
        },
        "answer": {"raw": options.placeholders.scrub(last_message),
                   "present": answer["present"],
                   "missingFields": answer["missingFields"],
                   "extraFields": answer["extraFields"],
                   "parseError": answer["parseError"],
                   "consumerCode": _consumer_code(answer)},
        "budgets": budget,
        "budgetFailures": failures,
        "budgetExceeded": sorted({failure["kind"] for failure in failures}),
        "contractBreaches": breaches,
        "measurementGaps": measurement_gaps,
        "files": {"clientEvents": CLIENT_LOG_NAME,
                  "lastMessage": LAST_MESSAGE_NAME,
                  "stdio": RELAY_LOG_NAME,
                  "clientStderr": CLIENT_STDERR_NAME,
                  "serverStderr": SERVER_STDERR_NAME},
    }
    return record


def server_contact(transport: dict, expected_tools: tuple[str, ...]) -> dict:
    """Whether this session actually reached the documentation server it evaluates."""
    advertised = tuple(transport.get("advertisedTools") or ())
    return {
        "transportAvailable": bool(transport.get("available")),
        "initialized": bool(transport.get("protocolVersion"))
                       and isinstance(transport.get("serverInfo"), dict),
        "toolsListed": transport.get("toolDefinitions") is not None,
        "advertisedTools": list(advertised),
        "expectedTools": list(expected_tools),
        "missingTools": [name for name in expected_tools if name not in advertised],
    }


def read_client_events(path: Path) -> list[dict]:
    events = []
    if not path.is_file():
        return events
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            events.append(json.loads(raw))
        except json.JSONDecodeError:
            continue
    return events


def _consumer_code(answer: dict) -> str:
    body = answer.get("json") or {}
    code = body.get("consumerCode")
    return code if isinstance(code, str) else ""


# ---------------------------------------------------------------------------
# Classification and aggregate report
# ---------------------------------------------------------------------------


CONSUMER_COMPILE_STATES = ("pending-parent-compile", "missing-code", "not-applicable")


def classify(record: dict) -> dict:
    """Separate every outcome; no dimension is upgraded by a nearby success.

    A budget failure is a task failure (`budgetFailureIsTaskFailure`), and so is a
    client error or a missing structured answer. Compilation and behavior are not
    inferred here: they stay pending until the parent's real compiler run, and a
    task that correctly declines code is not-applicable rather than compile-pass.
    """
    client = record["client"]
    answer = record["answer"]
    timed_out = bool(client["process"]["timedOut"])
    exit_code = client["process"]["exitCode"]
    client_error = timed_out or exit_code != 0 or not client["threadId"]
    budget_failure = bool(record.get("budgetExceeded"))
    missing_answer = not answer["present"]
    behavior_required = record["task"]["behaviorRequired"]
    has_code = isinstance(answer.get("consumerCode"), str) and answer["consumerCode"] != ""
    if has_code:
        compile_state = "pending-parent-compile"
        behavior_state = ("pending-parent-verification" if behavior_required else "not-required")
    elif behavior_required:
        compile_state = "missing-code"
        behavior_state = "not-applicable-without-code"
    else:
        compile_state = "not-applicable"
        behavior_state = "not-required"
    # Every arm documents itself through its own MCP server. A session that never
    # reached that server did not perform the arm under evaluation, whatever the
    # client event log claims.
    contact = record["toolUse"].get("serverContact") or {}
    no_server_contact = not (contact.get("transportAvailable")
                             and contact.get("initialized")
                             and contact.get("toolsListed")
                             and not contact.get("missingTools"))
    causes = []
    if client_error:
        causes.append("client-error")
    if budget_failure:
        causes.append("budget")
    if missing_answer:
        causes.append("answer-missing")
    if record.get("contractBreaches"):
        causes.append("contract-breach")
    if no_server_contact:
        causes.append("no-server-contact")
    if compile_state == "missing-code":
        causes.append("missing-consumer-code")
    reasons = []
    if timed_out:
        reasons.append(f"client exceeded the {record['budgets']['maximumSecondsPerTask']}s budget")
    if exit_code != 0 and not timed_out:
        reasons.append(f"client exited with {exit_code}")
    if not client["threadId"]:
        reasons.append("client never started a session")
    if budget_failure:
        reasons.append("fixed budget exceeded: " + "; ".join(
            f"{failure['kind']} limit {failure['limit']} observed {failure['observed']}"
            for failure in record.get("budgetFailures") or
            [{"kind": kind, "limit": "frozen", "observed": "recorded"}
             for kind in record["budgetExceeded"]]))
    if missing_answer:
        reasons.append(answer["parseError"] or "no structured answer")
    for breach in record.get("contractBreaches") or []:
        reasons.append(f"{breach['kind']} violated: {breach['rule']} "
                       f"(observed {breach['observed']})")
    if no_server_contact:
        missing = contact.get("missingTools") or []
        if not contact.get("transportAvailable"):
            reasons.append("the documentation server produced no stdio transcript")
        elif not contact.get("initialized") or not contact.get("toolsListed"):
            reasons.append("the documentation server was never initialized or listed")
        else:
            reasons.append("the documentation server did not advertise: "
                           + ", ".join(missing))
    if compile_state == "missing-code":
        reasons.append("no consumer code where the task requires generated code")
    return {
        "taskOutcome": "failed" if causes else "completed",
        "primaryCause": causes[0] if causes else "none",
        "causes": causes,
        "failureReasons": reasons,
        "clientError": client_error,
        "serverContact": contact,
        "budgetFailure": budget_failure,
        "budgetFailures": record.get("budgetFailures") or [],
        "contractBreaches": record.get("contractBreaches") or [],
        "answerMissing": missing_answer,
        "consumerCompile": compile_state,
        "consumerBehavior": behavior_state,
        "adjudication": "unadjudicated",
    }


def _metric_sum(rows: list[dict], key: str) -> tuple[float, int]:
    """Report a raw sum with its denominator; unmeasured values are excluded."""
    values = [row[key] for row in rows
              if isinstance(row.get(key), (int, float)) and not isinstance(row[key], bool)]
    return sum(values), len(values)


def aggregate(records: list[dict], protocol: dict, rubric: dict, options: RunOptions,
              manifest: dict) -> dict:
    rows = []
    for record in records:
        outcome = classify(record)
        rows.append({
            "task": record["task"]["id"],
            "arm": record["arm"],
            "ordinal": record["ordinal"],
            "armPosition": record["armPosition"],
            "record": record["session"]["relativeToOutput"] + "/" + RECORD_NAME,
            "outcome": outcome,
            "toolCalls": record["toolUse"]["calls"],
            "resultBytes": record["toolUse"]["resultBytes"],
            "elapsedMs": record["client"]["process"].get("elapsedMs"),
            "timedOut": record["client"]["process"]["timedOut"],
            "usage": record["client"]["usage"],
            "answerPresent": record["answer"]["present"],
            "missingAnswerFields": record["answer"]["missingFields"],
            "consumerCodeBytes": len(record["answer"]["consumerCode"].encode("utf-8")),
            "serverKind": record["session"].get("serverKind"),
            "serverContact": record["toolUse"]["serverContact"],
            "requiredFacts": [
                {"fact": fact, "verdict": None, "evidence": []}
                for fact in record["task"]["requiredFacts"]
            ],
        })
    totals = {}
    for arm in ARMS:
        arm_rows = [row for row in rows if row["arm"] == arm]
        if not arm_rows:
            continue
        calls, calls_measured = _metric_sum(arm_rows, "toolCalls")
        byte_total, bytes_measured = _metric_sum(arm_rows, "resultBytes")
        elapsed, elapsed_measured = _metric_sum(arm_rows, "elapsedMs")
        totals[arm] = {
            "attempted": len(arm_rows),
            "completed": sum(1 for row in arm_rows
                             if row["outcome"]["taskOutcome"] == "completed"),
            "failed": sum(1 for row in arm_rows if row["outcome"]["taskOutcome"] == "failed"),
            "failedByCause": {
                cause: sum(1 for row in arm_rows if cause in row["outcome"]["causes"])
                for cause in ("client-error", "contract-breach", "no-server-contact",
                              "budget", "answer-missing", "missing-consumer-code")
            },
            "budgetFailures": {
                kind: sum(1 for row in arm_rows
                          if any(failure["kind"] == kind
                                 for failure in row["outcome"]["budgetFailures"]))
                for kind in ("toolCalls", "documentBytes", "relayRefusal", "seconds")
            },
            "serverContactFailures": [
                row["task"] for row in arm_rows
                if not (row["serverContact"].get("transportAvailable")
                        and row["serverContact"].get("initialized")
                        and row["serverContact"].get("toolsListed")
                        and not row["serverContact"].get("missingTools"))
            ],
            "toolCalls": {"total": calls, "measuredTasks": calls_measured},
            "resultBytes": {"total": byte_total, "measuredTasks": bytes_measured},
            "elapsedMs": {"total": elapsed, "measuredTasks": elapsed_measured},
            "consumerCompile": {
                state: sum(1 for row in arm_rows if row["outcome"]["consumerCompile"] == state)
                for state in CONSUMER_COMPILE_STATES
            },
            "adjudicatedTasks": 0,
            "adjudicationDenominator": len(arm_rows),
        }
    pending = [row["task"] + ":" + row["arm"] for row in rows
               if row["outcome"]["consumerCompile"] == "pending-parent-compile"]
    gaps = sorted({gap for record in records for gap in record.get("measurementGaps", [])})
    return {
        "schemaVersion": "cjdoc.agent-evaluation-report/1",
        "status": "raw-observations",
        "claim": rubric.get("claim"),
        "denominator": rubric.get("taskDenominator"),
        "manifest": manifest,
        "budgets": options.budgets,
        "arms": list(ARMS),
        "taskOrder": "task-id-ascending; alternate path order by task ordinal",
        "completeness": {
            "frozenTasks": len(protocol["tasks"]),
            "frozenArms": len(ARMS),
            "observedRuns": len(rows),
            "completePair": (
                {row["task"] for row in rows} == {task["id"] for task in protocol["tasks"]}
                and {row["arm"] for row in rows} == set(ARMS)
                and all(sum(1 for row in rows
                            if row["task"] == task["id"] and row["arm"] == arm) == 1
                        for task in protocol["tasks"] for arm in ARMS)),
            "repetitionsPerTaskPerPath": 1,
        },
        "reportPerTask": True,
        "keepBothArmFailures": True,
        "measurementGaps": {gap: [record["task"]["id"] + ":" + record["arm"]
                                  for record in records
                                  if gap in record.get("measurementGaps", [])]
                            for gap in gaps},
        "records": rows,
        "totals": totals,
        "selection": {"bestOf": False, "retries": 0,
                      "retainedFailures": [row["task"] + ":" + row["arm"] for row in rows
                                           if row["outcome"]["taskOutcome"] == "failed"]},
        "scoring": {
            "state": "unadjudicated",
            "reason": ("deterministic identity, signature, citation and compile evidence require "
                       "the parent's real compiler run and per-required-fact adjudication; this "
                       "report records observations only and assigns no score"),
            "dimensions": {name: {"state": "not-adjudicated"}
                           for name in protocol["scoreDimensions"]},
            "requiredFactVerdicts": "null until adjudicated",
            "naturalLanguageScoring": "unadjudicated",
        },
        "consumerCompile": {
            "state": "pending-parent-verification" if pending else "nothing-to-compile",
            "pending": pending,
            "notApplicableTasks": [row["task"] + ":" + row["arm"] for row in rows
                                   if row["outcome"]["consumerCompile"] == "not-applicable"],
            "missingConsumerCode": [row["task"] + ":" + row["arm"] for row in rows
                                    if row["outcome"]["consumerCompile"] == "missing-code"],
        },
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _planned_session(options: "RunOptions", run: dict) -> dict:
    """One dry-run entry: the real server and relay commands this arm would launch."""
    placeholder = Path("<session>")
    server = arm_server(options, placeholder, run["arm"])
    prompt_root = options.baseline_view if run["arm"] == "baseline-html-index" \
        else options.baseline
    return {
        "task": run["task"]["id"],
        "arm": run["arm"],
        "serverKind": server["kind"],
        "serverCommand": options.placeholders.command(server["nativeCommand"]),
        "relayCommand": options.placeholders.command(server["command"]),
        "expectedTools": server["expectedTools"],
        "prompt": options.placeholders.scrub(
            task_prompt(options.protocol, run, run["arm"], prompt_root)),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run the frozen paired Agent evaluation with real client and server processes.",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    parser.add_argument("--binary", required=True, type=Path,
                        help="real cjdoc executable (baseline copy for the baseline arm, "
                             "current build for the MCP arm)")
    parser.add_argument("--baseline", type=Path,
                        help="captured immutable static documentation tree")
    parser.add_argument("--site", action="append", default=[], metavar="NAME=RELATIVE_PATH",
                        help="captured site the baseline server may publish (repeatable)")
    parser.add_argument("--snapshot", action="append", default=[], type=Path,
                        help="docs.json or machine manifest for `cjdoc mcp --snapshot` (repeatable)")
    parser.add_argument("--output", required=True, type=Path,
                        help="private run directory receiving raw traces and the report")
    parser.add_argument("--protocol", default=DEFAULT_PROTOCOL, type=Path)
    parser.add_argument("--rubric", default=DEFAULT_RUBRIC, type=Path)
    parser.add_argument("--codex", default=os.environ.get("CJDOC_EVALUATION_CODEX", "codex"))
    parser.add_argument("--arm", action="append", choices=ARMS, help="restrict arms (repeatable)")
    parser.add_argument("--task", action="append", help="restrict task ids (repeatable)")
    parser.add_argument("--max-tool-calls", type=int, help="tighten the frozen call budget")
    parser.add_argument("--max-document-bytes", type=int, help="tighten the frozen byte budget")
    parser.add_argument("--max-seconds", type=int, help="tighten the frozen time budget")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the plan and placeholder commands without invoking anything")
    return parser


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["relay"]:
        return relay_main(argv[1:])
    args = build_parser().parse_args(argv)
    try:
        protocol = load_protocol(args.protocol)
        rubric = load_rubric(args.rubric, protocol)
    except ProtocolError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    options = RunOptions(args, protocol, rubric)
    options.validate_arms()
    runs = options.selected()
    if not runs:
        raise SystemExit("error: no task/arm combination selected")
    options.placeholders = Placeholders([
        (options.binary, "<binary>"),
        (Path(os.path.abspath(options.codex)), "<codex>"),
        *([(options.baseline, "<baseline>")] if options.baseline else []),
        *[(Path(snapshot), f"<snapshot:{index}>")
          for index, snapshot in enumerate(options.snapshots, start=1)],
        (options.output, "<output>"),
        (Path.home(), "$HOME"),
        (REPO, "<repo>"),
        (Path(tempfile.gettempdir()), "$TMPDIR"),
    ])
    disabled_features, enabled_features = client_feature_policy(protocol)
    host = shutil.which("codex-code-mode-host") if enabled_features else None
    manifest = {
        "schemaVersion": "cjdoc.agent-evaluation-run/1",
        "protocol": {"path": repo_relative(args.protocol), "sha256": digest_of(args.protocol)},
        "rubric": {"path": repo_relative(args.rubric), "sha256": digest_of(args.rubric)},
        "baselineRevision": protocol.get("baselineRevision"),
        "binary": {"label": "<binary>", "sha256": digest_of(options.binary)},
        "harness": {"runnerSha256": digest_of(Path(__file__).resolve()),
                    "baselineServerSha256": digest_of(BASELINE_SERVER)},
        "snapshots": [{"label": f"<snapshot:{index}>", "sha256": digest_of(path)}
                      for index, path in enumerate(options.snapshots, start=1)],
        "client": protocol["client"],
        "mcpProtocol": protocol.get("protocol"),
        "disabledClientFeatures": list(disabled_features),
        "enabledClientFeatures": list(enabled_features),
        "clientTransport": protocol.get("clientTransport", "legacy-host-disabled"),
        "requiredDocumentationServer": bool(enabled_features),
        "factProtocol": protocol.get("factProtocol"),
        "codeModeHost": ({"name": "codex-code-mode-host", "sha256": digest_of(Path(host))}
                         if host else None),
        "nativeRuntimeEnvironmentKeys": (list(NATIVE_RUNTIME_ENVIRONMENT)
                                          if enabled_features else []),
        "webSearch": 'web_search="disabled" (top-level client setting)',
        "nativeContract": "<binary> mcp --snapshot <PATH> [--snapshot <PATH> ...]",
        "baselineContract": (f"{sys.executable} agent_baseline_mcp.py --baseline "
                             "<published view> --site NAME=PATH ..."),
        "relayContract": ("both arms: python agent_evaluation.py relay --log <session> "
                          "--max-tool-calls N --max-result-bytes N --cwd <session> -- "
                          "<server command>"),
        "relay": "stdio JSON-RPC forwarded one line at a time; budgets enforced at the relay",
        "runs": [{"task": run["task"]["id"], "arm": run["arm"],
                  "ordinal": run["ordinal"], "armPosition": run["armPosition"]} for run in runs],
        "budgets": options.budgets,
    }
    if args.dry_run:
        plan = dict(manifest, dryRun=True, sessions=[_planned_session(options, run)
                                                     for run in runs])
        print(strict_dumps(options.placeholders.scrub(plan), ensure_ascii=False, indent=2))
        return 0
    if options.output.exists():
        # Never mix a rerun into stored traces: the frozen protocol keeps one
        # observation per task and path, so a second run needs its own directory.
        if not options.output.is_dir() or any(options.output.iterdir()):
            raise SystemExit(
                f"error: refusing to reuse a non-empty output directory: {options.output}")
    options.output.mkdir(mode=0o700, parents=True, exist_ok=True)
    if options.baseline_view is not None:
        manifest["baselineView"] = prepare_baseline_view(options.baseline,
                                                        options.baseline_view)
    write_json(options.output / MANIFEST_NAME, options.placeholders.scrub(manifest))
    records = []
    for run in runs:
        session = options.output / "sessions" / run["task"]["id"] / run["arm"]
        record = run_one(options, run, session)
        write_json(session / RECORD_NAME, record)
        records.append(record)
        print(f"{run['task']['id']} {run['arm']}: {classify(record)['taskOutcome']}",
              file=sys.stderr)
    report = aggregate(records, protocol, rubric, options, manifest)
    write_json(options.output / REPORT_NAME, options.placeholders.scrub(report))
    print(options.output / REPORT_NAME)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
