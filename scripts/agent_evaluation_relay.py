#!/usr/bin/env python3
"""The recording, budgeting MCP stdio relay and its transcript reader.

One real documentation server runs behind this relay, in both evaluation arms.
Every JSON-RPC line is forwarded verbatim, recorded with its byte span, and
checked against the task's fixed tool-call and document-byte budgets. The
transcript it writes is authoritative for what actually crossed stdio, so
`read_relay_log` re-derives those facts instead of trusting a closing receipt.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys
import threading
import time
from typing import Any

sys.dont_write_bytecode = True
try:
    from .strict_json import strict_dumps
except ImportError:  # Direct script execution.
    from strict_json import strict_dumps

RELAY_LOG_NAME = "mcp-stdio.jsonl"
SERVER_STDERR_NAME = "server.stderr.log"
ENFORCEMENT_ERROR = "budget-exceeded"
SERVER_SHUTDOWN_SECONDS = 10


def compact(value: Any) -> str:
    return strict_dumps(value, ensure_ascii=False, separators=(",", ":"))


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


def _tool_definitions(parsed: dict) -> list[dict] | None:
    """Tool names and input schemas from one tools/list result, if that is what it is."""
    result = parsed.get("result")
    tools = result.get("tools") if isinstance(result, dict) else None
    if not isinstance(tools, list):
        return None
    return [{"name": tool.get("name"), "description": tool.get("description"),
             "inputSchema": tool.get("inputSchema"), "annotations": tool.get("annotations")}
            for tool in tools if isinstance(tool, dict)]


def _absorb_transcript_line(summary: dict, raw: str) -> None:
    """Fold one recorded JSONL line into the transport summary."""
    try:
        item = json.loads(raw)
    except json.JSONDecodeError:
        summary["malformedLines"] += 1
        return
    if not isinstance(item, dict):
        summary["malformedLines"] += 1
        return
    if item.get("kind") == "budget":
        summary["budget"] = {key: item.get(key) for key in
                             ("toolCalls", "resultBytes", "exceeded")}
        return
    direction = item.get("direction")
    if direction not in ("client->server", "server->client"):
        summary["malformedLines"] += 1
        return
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


def _conclude_totals(summary: dict) -> None:
    """Decide what the transcript proves about totals, never filling gaps with zero."""
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
        _absorb_transcript_line(summary, raw)
    _conclude_totals(summary)
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
