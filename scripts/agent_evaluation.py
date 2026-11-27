#!/usr/bin/env python3
"""Run the frozen paired Agent evaluation against real client and server processes.

Two arms consume the same captured v17 documentation, and both reach it the same
way: one real MCP stdio server behind one recording, budgeting relay, with every
non-document client tool disabled.

* `baseline-html-index` -- `agent_baseline_mcp.py` publishes only the captured
  pre-change static site's llms text, machine indexes and rendered pages. The run
  gets its own published-only view, and only explicitly named sites are served.
* `shared-query-mcp`    -- the native `cjdoc mcp --snapshot ...` server.

Nothing here scores a model. The runner records what actually happened: the
client's own JSONL events, the last structured answer, and every JSON-RPC line
that crossed each arm's transport (definitions, requests, results, sizes,
timings). Budgets are fixed by `tests/agent/evaluation-protocol-v2.json`, every
failure is retained, and no task is retried. Compilation and behavioral
adjudication belong to the parent's real compiler run; this tool only marks
where they are still outstanding.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any

sys.dont_write_bytecode = True
if __package__:
    from .agent_evaluation_protocol import (
        ARMS, DEFAULT_PROTOCOL, DEFAULT_RUBRIC, PROTOCOL_LOADER_PATH, REPO,
        ProtocolError, RunOptions, arm_site_arguments, digest_of, load_protocol,
        load_rubric, prepare_baseline_view, verify_source_slices,
    )
    from .strict_json import strict_dumps
else:
    from agent_evaluation_protocol import (
        ARMS, DEFAULT_PROTOCOL, DEFAULT_RUBRIC, PROTOCOL_LOADER_PATH, REPO,
        ProtocolError, RunOptions, arm_site_arguments, digest_of, load_protocol,
        load_rubric, prepare_baseline_view, verify_source_slices,
    )
    from strict_json import strict_dumps

try:
    from agent_evaluation_relay import (RELAY_LOG_NAME, SERVER_STDERR_NAME,
                                        read_relay_log, relay_main)
    from agent_evaluation_outcomes import RECORD_NAME, aggregate, classify
except ImportError:  # Package execution.
    from .agent_evaluation_relay import (RELAY_LOG_NAME, SERVER_STDERR_NAME,
                                         read_relay_log, relay_main)
    from .agent_evaluation_outcomes import RECORD_NAME, aggregate, classify

MCP_SERVER_NAME = "cjdoc"
CLIENT_LOG_NAME = "client.jsonl"
CLIENT_STDERR_NAME = "client.stderr.log"
LAST_MESSAGE_NAME = "last-message.json"
REPORT_NAME = "report.json"
MANIFEST_NAME = "run-manifest.json"
RELENDING_ARGUMENT = "--snapshot"
GROUP_GRACE_SECONDS = 0.3
MCP_STARTUP_SECONDS = 120


def write_json(path: Path, value: Any) -> None:
    path.write_text(strict_dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def repo_relative(path: Path) -> str:
    """Describe a path inside this repository relative to it, else by label."""
    try:
        return Path(os.path.abspath(path)).relative_to(REPO).as_posix()
    except ValueError:
        return "<external>"


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


# ---------------------------------------------------------------------------
# Client invocation: one measured process group per task and arm
# ---------------------------------------------------------------------------


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


def measured_session(options: RunOptions, run: dict, session: Path) -> dict:
    """Launch the arm's real server behind the relay and run the client exactly once."""
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
    return {"server": server, "prompt": prompt, "command": command, "process": process}


def session_answer(options: RunOptions, session: Path, summary: dict,
                   transport: dict, server: dict) -> dict:
    """Server contact and the client's structured answer, read from the captured files."""
    contact = server_contact(transport, server["expectedTools"])
    last_message_path = session / LAST_MESSAGE_NAME
    last_message = (last_message_path.read_text(encoding="utf-8", errors="replace")
                    if last_message_path.is_file() else None)
    if last_message is None:
        last_message = summary["lastAgentMessage"]
    return {"contact": contact, "raw": last_message,
            "parsed": parse_answer(last_message, options.protocol["answerFields"])}


def budget_audit(summary: dict, transport: dict, result_bytes: int | None,
                 process: dict, budget: dict) -> dict:
    """Budget failures, contract breaches and measurement gaps, in ledger order."""
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
    return {"failures": failures, "breaches": breaches, "gaps": measurement_gaps}


def run_one(options: RunOptions, run: dict, session: Path) -> dict:
    """Execute exactly one client session; never retried, never reselected."""
    task = run["task"]
    arm = run["arm"]
    measured = measured_session(options, run, session)
    server, process = measured["server"], measured["process"]
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
    answer = session_answer(options, session, summary, transport, server)
    budget = dict(options.budgets)
    audit = budget_audit(summary, transport, result_bytes, process, budget)
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
                    "prompt": options.placeholders.scrub(measured["prompt"]),
                    "serverKind": server["kind"],
                    "server": options.placeholders.scrub(server["nativeCommand"]),
                    "serverCommand": options.placeholders.command(server["command"]),
                    "expectedTools": server["expectedTools"],
                    "runtimeEnvironment": options.placeholders.scrub(server.get("env", {}))},
        "client": {
            "command": options.placeholders.command(measured["command"]),
            "process": process,
            "threadId": summary["threadId"],
            "usage": summary["usage"],
            "failedTurns": summary["failedTurns"],
            "errors": options.placeholders.scrub(summary["errors"]),
            "eventTypes": summary["eventTypes"],
        },
        "toolUse": {
            "serverContact": answer["contact"],
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
        "answer": {"raw": options.placeholders.scrub(answer["raw"]),
                   "present": answer["parsed"]["present"],
                   "missingFields": answer["parsed"]["missingFields"],
                   "extraFields": answer["parsed"]["extraFields"],
                   "parseError": answer["parsed"]["parseError"],
                   "consumerCode": _consumer_code(answer["parsed"])},
        "budgets": budget,
        "budgetFailures": audit["failures"],
        "budgetExceeded": sorted({failure["kind"] for failure in audit["failures"]}),
        "contractBreaches": audit["breaches"],
        "measurementGaps": audit["gaps"],
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
    parser.add_argument("--project-root", type=Path, default=REPO,
                        help="captured source checkout for the frozen citations")
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


def _run_placeholders(options: RunOptions) -> Placeholders:
    """Map every machine-specific root this invocation touches to a stable label."""
    return Placeholders([
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


def run_manifest(options: RunOptions, args: argparse.Namespace, runs: list[dict]) -> dict:
    """Record the invocation inputs and entry-point identities before sessions start."""
    protocol = options.protocol
    disabled_features, enabled_features = client_feature_policy(protocol)
    host = shutil.which("codex-code-mode-host") if enabled_features else None
    return {
        "schemaVersion": "cjdoc.agent-evaluation-run/1",
        "protocol": {"path": repo_relative(args.protocol), "sha256": digest_of(args.protocol)},
        "rubric": {"path": repo_relative(args.rubric), "sha256": digest_of(args.rubric)},
        "baselineRevision": protocol.get("baselineRevision"),
        **({"sourceCitationBaseline": protocol["sourceCitationBaseline"]}
           if "sourceCitationBaseline" in protocol else {}),
        "binary": {"label": "<binary>", "sha256": digest_of(options.binary)},
        # The loader lives outside the entry point; pin its bytes independently.
        "harness": {"runnerSha256": digest_of(Path(__file__).resolve()),
                    "baselineServerSha256": digest_of(BASELINE_SERVER),
                    "protocolLoaderSha256": digest_of(PROTOCOL_LOADER_PATH)},
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


def run_sessions(options: RunOptions, runs: list[dict]) -> list[dict]:
    """Execute every planned session in order and keep each record on disk as it lands."""
    records = []
    for run in runs:
        session = options.output / "sessions" / run["task"]["id"] / run["arm"]
        record = run_one(options, run, session)
        write_json(session / RECORD_NAME, record)
        records.append(record)
        print(f"{run['task']['id']} {run['arm']}: {classify(record)['taskOutcome']}",
              file=sys.stderr)
    return records


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["relay"]:
        return relay_main(argv[1:])
    args = build_parser().parse_args(argv)
    try:
        protocol = load_protocol(args.protocol)
        rubric = load_rubric(args.rubric, protocol)
        if "sourceCitationBaseline" in protocol:
            verify_source_slices(protocol, args.project_root)
    except ProtocolError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    options = RunOptions(args, protocol, rubric)
    options.validate_arms()
    runs = options.selected()
    if not runs:
        raise SystemExit("error: no task/arm combination selected")
    options.placeholders = _run_placeholders(options)
    manifest = run_manifest(options, args, runs)
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
    records = run_sessions(options, runs)
    report = aggregate(records, protocol, rubric, options, manifest)
    write_json(options.output / REPORT_NAME, options.placeholders.scrub(report))
    print(options.output / REPORT_NAME)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
