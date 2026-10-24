#!/usr/bin/env python3
"""Native `cjdoc mcp` protocol integration against a real process and snapshots.

These tests drive the compiled binary over the MCP 2025-11-25 stdio transport:
newline-delimited UTF-8 JSON-RPC 2.0 on stdin/stdout. They never import the
Cangjie query core, never stub `execute`, and never call a model. Query results
are compared field-for-field with the CLI contract (`cjdoc query --snapshot ...
--request -`), so the two surfaces must stay byte-equivalent as JSON objects.

Usage:
    python3 scripts/test_query_mcp.py --binary target/release/bin/cjdoc \
        --snapshot docs.json
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import unittest

sys.dont_write_bytecode = True

PROTOCOL_VERSION = "2025-11-25"
MCP_REQUEST_LIMIT = 1024 * 1024
TOOL_NAMES = ("resolve_docs", "search", "get_symbol")
DOMAIN_STATUSES = frozenset({"ok", "ambiguous", "not_found", "source_incomplete"})
ALL_STATUSES = DOMAIN_STATUSES | {
    "budget_exceeded", "stale_cursor", "invalid_request", "scope_mismatch",
    "resource_limit", "unavailable",
}
# Documented CLI exit contract for `cjdoc query`.
EXIT_CODES = {"ok": 0, "ambiguous": 0, "not_found": 0, "source_incomplete": 0,
              "invalid_request": 2, "scope_mismatch": 2, "stale_cursor": 2,
              "unavailable": 3, "resource_limit": 3, "budget_exceeded": 3}

PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602

BINARY: Path | None = None
SNAPSHOTS: tuple[Path, ...] = ()
TIMEOUT = 120.0
_SHARED: "McpProcess | None" = None
_EOF = object()


def _encode(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _decode_exactly(text: bytes, label: str) -> object:
    """Parse one JSON document and reject trailing non-whitespace output."""
    decoded = text.decode("utf-8")
    try:
        value, end = json.JSONDecoder().raw_decode(decoded.lstrip())
    except json.JSONDecodeError as error:
        raise AssertionError(f"{label} is not JSON: {decoded[:200]!r}") from error
    if decoded.lstrip()[end:].strip():
        raise AssertionError(f"{label} contains output after the JSON document")
    return value


class McpProcess:
    """One live `cjdoc mcp` child process with message-level assertions."""

    def __init__(self, binary: Path, snapshots: tuple[Path, ...], timeout: float = TIMEOUT):
        command = [os.fspath(binary), "mcp"]
        for snapshot in snapshots:
            command.extend(("--snapshot", os.fspath(snapshot)))
        self.timeout = timeout
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.messages: "queue.Queue[object]" = queue.Queue()
        self.seen: list[dict] = []
        self.stderr = bytearray()
        self.next_id = 1
        self._stdout = threading.Thread(target=self._pump_stdout, daemon=True)
        self._stderr = threading.Thread(target=self._pump_stderr, daemon=True)
        self._stdout.start()
        self._stderr.start()

    # -- transport -----------------------------------------------------
    def _pump_stdout(self) -> None:
        assert self.process.stdout is not None
        try:
            for raw in self.process.stdout:
                self.messages.put(raw)
        finally:
            self.messages.put(_EOF)

    def _pump_stderr(self) -> None:
        assert self.process.stderr is not None
        while True:
            chunk = self.process.stderr.read(8192)
            if not chunk:
                return
            self.stderr.extend(chunk)

    def send_raw(self, data: bytes) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def send(self, message: object) -> None:
        self.send_raw(_encode(message) + b"\n")

    def notify(self, method: str, params: object | None = None) -> None:
        message: dict = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)

    def read(self) -> dict:
        item = self.messages.get(timeout=self.timeout)
        if item is _EOF:
            raise EOFError("cjdoc mcp closed stdout before answering")
        assert isinstance(item, bytes)
        try:
            message = json.loads(item.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise AssertionError(f"stdout line is not UTF-8 JSON: {item[:200]!r}") from error
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            raise AssertionError(f"stdout line is not a JSON-RPC 2.0 object: {item[:200]!r}")
        self.seen.append(message)
        return message

    def next_request_id(self) -> int:
        identifier = self.next_id
        self.next_id += 1
        return identifier

    def request(self, method: str, params: object | None = None,
                id: object | None = None) -> dict:
        identifier = self.next_request_id() if id is None else id
        message: dict = {"jsonrpc": "2.0", "id": identifier, "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)
        return self.response(identifier)

    def response(self, identifier: object) -> dict:
        message = self.read()
        if "id" not in message:
            raise AssertionError(f"expected a response, got a notification: {message}")
        if message["id"] != identifier or type(message["id"]) is not type(identifier):
            raise AssertionError(
                f"response id {message['id']!r} does not match request id {identifier!r}")
        if ("result" in message) == ("error" in message):
            raise AssertionError(f"response must carry exactly one of result/error: {message}")
        return message

    def result(self, method: str, params: object | None = None,
               id: object | None = None) -> dict:
        message = self.request(method, params, id)
        if "result" not in message:
            raise AssertionError(f"{method} failed: {message['error']}")
        return message["result"]

    def error(self, method: str, params: object | None = None,
              id: object | None = None) -> dict:
        message = self.request(method, params, id)
        if "error" not in message:
            raise AssertionError(f"{method} unexpectedly succeeded: {message['result']}")
        return message["error"]

    # -- lifecycle -----------------------------------------------------
    def initialize(self, version: object = PROTOCOL_VERSION) -> dict:
        return self.result("initialize", {
            "protocolVersion": version,
            "capabilities": {},
            "clientInfo": {"name": "cjdoc-protocol-test", "version": "1"},
        })

    def mark_initialized(self) -> None:
        self.notify("notifications/initialized")

    def close_stdin(self) -> None:
        if self.process.stdin is not None and not self.process.stdin.closed:
            self.process.stdin.close()

    def wait(self) -> int:
        try:
            try:
                return self.process.wait(timeout=self.timeout)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=30)
                raise AssertionError("cjdoc mcp did not exit after stdin closed")
        finally:
            self._stdout.join(timeout=30)
            self._stderr.join(timeout=30)
            for stream in (self.process.stdout, self.process.stderr):
                if stream is not None:
                    stream.close()

    def close(self) -> int:
        self.close_stdin()
        return self.wait()

    def trailing_messages(self) -> list[object]:
        leftovers: list[object] = []
        while True:
            try:
                item = self.messages.get_nowait()
            except queue.Empty:
                return leftovers
            if item is _EOF:
                continue
            leftovers.append(item)

    def stderr_text(self) -> str:
        return self.stderr.decode("utf-8", errors="replace")


def spawn_process() -> McpProcess:
    assert BINARY is not None
    return McpProcess(BINARY, SNAPSHOTS)


def initialized_process() -> McpProcess:
    global _SHARED
    if _SHARED is None:
        process = spawn_process()
        try:
            process.initialize()
            process.mark_initialized()
        except BaseException:
            process.close()
            raise
        _SHARED = process
    return _SHARED


def cli_query(request: dict) -> tuple[int, dict]:
    assert BINARY is not None
    command = [os.fspath(BINARY), "query"]
    for snapshot in SNAPSHOTS:
        command.extend(("--snapshot", os.fspath(snapshot)))
    command.extend(("--request", "-"))
    completed = subprocess.run(command, input=_encode(request) + b"\n", stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=TIMEOUT)
    parsed = _decode_exactly(completed.stdout, "cjdoc query stdout")
    if not isinstance(parsed, dict):
        raise AssertionError(f"cjdoc query returned a non-object: {parsed!r}")
    return completed.returncode, parsed


def assert_query_result(test: unittest.TestCase, structured: dict) -> None:
    test.assertEqual(structured.get("schemaVersion"), "cjdoc.query-result/1")
    status = structured.get("status")
    test.assertIn(status, ALL_STATUSES, f"undeclared status: {status!r}")
    test.assertIsInstance(structured.get("text"), str)
    test.assertTrue(structured["text"], "query result text must not be empty")


class DiscoveryTests(unittest.TestCase):
    def test_initialize_negotiates_version_and_tools_only(self):
        self.assertEqual(initialized_process().result("ping"), {})
        # The shared process answered initialize already; a fresh one proves the
        # negotiation payload itself, including an unknown requested version.
        process = spawn_process()
        try:
            negotiated = process.initialize("2024-11-05")
            self.assertEqual(negotiated["protocolVersion"], PROTOCOL_VERSION)
            capabilities = negotiated["capabilities"]
            self.assertIsInstance(capabilities["tools"], dict)
            self.assertNotIn("resources", capabilities)
            self.assertNotIn("prompts", capabilities)
            self.assertNotIn("logging", capabilities)
            self.assertFalse(capabilities["tools"].get("listChanged", False))
            self.assertEqual(negotiated["serverInfo"]["name"], "cjdoc")
            self.assertIsInstance(negotiated["serverInfo"]["version"], str)
            self.assertTrue(negotiated["serverInfo"]["version"])
            process.mark_initialized()
            second = process.error("initialize", {
                "protocolVersion": PROTOCOL_VERSION, "capabilities": {},
                "clientInfo": {"name": "again", "version": "1"}})
            self.assertEqual(second["code"], INVALID_REQUEST)
            self.assertEqual(process.result("ping"), {})
        finally:
            self.assertEqual(process.close(), 0)

    def test_tools_list_is_stable_and_omits_operation(self):
        process = initialized_process()
        first = process.result("tools/list")
        second = process.result("tools/list")
        self.assertEqual(_encode(first), _encode(second))
        self.assertNotIn("nextCursor", first)
        tools = first["tools"]
        self.assertEqual([tool["name"] for tool in tools], list(TOOL_NAMES))
        for tool in tools:
            self.assertIsInstance(tool["title"], str)
            self.assertTrue(tool["description"])
            input_schema = tool["inputSchema"]
            self.assertEqual(input_schema.get("type"), "object")
            properties = input_schema.get("properties")
            self.assertIsInstance(properties, dict)
            self.assertNotIn("operation", properties)
            self.assertNotIn("schemaVersion", properties)
            required = input_schema.get("required", [])
            self.assertNotIn("operation", required)
            self.assertNotIn("schemaVersion", required)
            self.assertEqual(tool["outputSchema"].get("type"), "object")
            self.assertTrue(tool["annotations"]["readOnlyHint"])

    def test_tools_list_rejects_a_cursor_it_never_issued(self):
        process = initialized_process()
        error = process.error("tools/list", {"cursor": "bogus"})
        self.assertEqual(error["code"], INVALID_PARAMS)


class ToolsCallTests(unittest.TestCase):
    PROBES = (
        ("resolve_docs", {"query": "cjdoc", "limit": 3}),
        ("search", {"query": "cjdoc", "limit": 3}),
        ("get_symbol", {"qualifiedName": "missing.Symbol"}),
        ("get_symbol", {"name": "NonexistentSymbolXyz"}),
    )

    def call(self, name: str, arguments: dict) -> tuple[dict, dict]:
        result = initialized_process().result("tools/call",
                                              {"name": name, "arguments": arguments})
        return result, result["structuredContent"]

    def test_results_preserve_identity_status_and_error_mapping(self):
        for name, arguments in self.PROBES:
            with self.subTest(tool=name, arguments=arguments):
                result, structured = self.call(name, arguments)
                assert_query_result(self, structured)
                # Domain outcomes are successful calls; every other declared
                # status must be flagged for the model to retry or report.
                self.assertEqual(result["isError"],
                                 structured["status"] not in DOMAIN_STATUSES)
                content = result["content"]
                self.assertEqual(len(content), 1)
                self.assertEqual(content[0]["type"], "text")
                self.assertEqual(content[0]["text"], structured["text"])

    def test_missing_symbols_are_never_reported_as_success(self):
        for name, arguments in (("get_symbol", {"qualifiedName": "missing.Symbol"}),
                                ("get_symbol", {"name": "NonexistentSymbolXyz"})):
            with self.subTest(arguments=arguments):
                result, structured = self.call(name, arguments)
                assert_query_result(self, structured)
                self.assertNotEqual(structured["status"], "ok")
                self.assertEqual(result["isError"],
                                 structured["status"] not in DOMAIN_STATUSES)
                self.assertEqual(result["content"][0]["text"], structured["text"])

    def test_invalid_argument_fields_fail_the_call_not_the_protocol(self):
        result, structured = self.call("resolve_docs",
                                       {"query": "cjdoc", "limit": 1, "unknownField": True})
        assert_query_result(self, structured)
        self.assertEqual(structured["status"], "invalid_request")
        self.assertTrue(result["isError"])
        self.assertEqual(result["content"][0]["text"], structured["text"])

    def test_operation_field_is_rejected_not_forwarded(self):
        error = initialized_process().error("tools/call", {
            "name": "resolve_docs",
            "arguments": {"operation": "search", "query": "cjdoc"}})
        self.assertEqual(error["code"], INVALID_PARAMS)
        self.assertIn("operation", error["message"])

    def test_unknown_tool_and_non_object_arguments_are_protocol_errors(self):
        process = initialized_process()
        unknown = process.error("tools/call", {"name": "read_file", "arguments": {}})
        self.assertEqual(unknown["code"], INVALID_PARAMS)
        missing = process.error("tools/call", {"arguments": {}})
        self.assertEqual(missing["code"], INVALID_PARAMS)
        wrong = process.error("tools/call", {"name": "search", "arguments": []})
        self.assertEqual(wrong["code"], INVALID_PARAMS)

    def test_cli_and_mcp_return_the_same_object(self):
        process = initialized_process()
        for name, arguments in self.PROBES + (
                ("resolve_docs", {"query": "cjdoc", "limit": 1, "unknownField": True}),):
            with self.subTest(tool=name, arguments=arguments):
                mcp_result = process.result("tools/call",
                                            {"name": name, "arguments": arguments})
                structured = mcp_result["structuredContent"]
                exit_code, cli_result = cli_query({"operation": name, **arguments})
                self.assertEqual(structured, cli_result)
                self.assertEqual(exit_code, EXIT_CODES[cli_result["status"]])
                self.assertEqual(mcp_result["isError"],
                                 cli_result["status"] not in DOMAIN_STATUSES)
                self.assertEqual(mcp_result["content"][0]["text"], cli_result["text"])

    def test_optional_request_schema_version_reaches_the_core(self):
        result, structured = self.call("resolve_docs", {
            "schemaVersion": "cjdoc.query-request/1", "query": "cjdoc", "limit": 1})
        assert_query_result(self, structured)
        self.assertIn(structured["status"], ALL_STATUSES)
        self.assertNotEqual(structured["schemaVersion"], "cjdoc.query-request/1")


class MalformedRequestTests(unittest.TestCase):
    def test_parse_invalid_and_batch_failures_carry_null_id(self):
        process = initialized_process()
        process.send_raw(b"{not json\n")
        broken = process.response(None)
        self.assertEqual(broken["error"]["code"], PARSE_ERROR)
        process.send_raw(b"\xff\xfe\n")
        bad_utf8 = process.response(None)
        self.assertEqual(bad_utf8["error"]["code"], PARSE_ERROR)
        process.send_raw(b"[]\n")
        batch = process.response(None)
        self.assertEqual(batch["error"]["code"], INVALID_REQUEST)
        process.send_raw(b'"text"\n')
        scalar = process.response(None)
        self.assertEqual(scalar["error"]["code"], INVALID_REQUEST)

    def test_structural_requests_reject_their_own_defects(self):
        process = initialized_process()
        cases = (
            ({"id": 71, "method": "tools/list"}, 71, INVALID_REQUEST),
            ({"jsonrpc": "1.0", "id": 72, "method": "tools/list"}, 72, INVALID_REQUEST),
            ({"jsonrpc": "2.0", "id": 73}, 73, INVALID_REQUEST),
            ({"jsonrpc": "2.0", "id": True, "method": "tools/list"}, None, INVALID_REQUEST),
            ({"jsonrpc": "2.0", "id": 1.5, "method": "tools/list"}, None, INVALID_REQUEST),
            ({"jsonrpc": "2.0", "id": None, "method": "tools/list"}, None, INVALID_REQUEST),
            ({"jsonrpc": "2.0", "id": 74, "method": 7}, 74, INVALID_REQUEST),
            ({"jsonrpc": "2.0", "id": 75, "method": ""}, 75, INVALID_REQUEST),
            ({"jsonrpc": "2.0", "id": 76, "method": "tools/list", "params": []}, 76,
             INVALID_PARAMS),
        )
        for message, expected_id, expected_code in cases:
            with self.subTest(message=message):
                process.send(message)
                response = process.response(expected_id)
                self.assertEqual(response["error"]["code"], expected_code)

    def test_integer_valued_decimal_and_exponent_ids_remain_exact(self):
        process = initialized_process()
        for literal, expected in ((b"1e3", 1000), (b"1.0", 1),
                                  (b"1000e-3", 1), (b"1.25e2", 125),
                                  (b"-3.0", -3), (b"0e-10000", 0)):
            with self.subTest(literal=literal):
                process.send_raw(b'{"jsonrpc":"2.0","id":' + literal +
                                 b',"method":"ping"}\n')
                response = process.read()
                self.assertEqual(response["id"], expected)
                self.assertEqual(response["result"], {})
        for literal in (b"1e-3", b"0.1", b"100e-3"):
            with self.subTest(literal=literal):
                process.send_raw(b'{"jsonrpc":"2.0","id":' + literal +
                                 b',"method":"ping"}\n')
                response = process.response(None)
                self.assertEqual(response["error"]["code"], INVALID_REQUEST)

    def test_unknown_method_and_ping_keep_ids_and_stream_order(self):
        process = initialized_process()
        request_id = "req-\u03b1"
        error = process.error("tools/does-not-exist", id=request_id)
        self.assertEqual(error["code"], METHOD_NOT_FOUND)
        self.assertIn("tools/does-not-exist", error["message"])
        for identifier in (0, -7, 2 ** 53 + 1, "", "a b"):
            with self.subTest(id=identifier):
                self.assertEqual(process.result("ping", id=identifier), {})

    def test_stray_client_response_is_ignored(self):
        process = initialized_process()
        process.send({"jsonrpc": "2.0", "id": 999, "result": {}})
        process.send({"jsonrpc": "2.0", "id": 998, "error": {"code": -32000, "message": "x"}})
        self.assertEqual(process.result("ping", id="after-stray"), {})

    def test_oversized_request_is_rejected_without_killing_the_stream(self):
        process = initialized_process()
        process.send_raw(b"{\"" + b"x" * (MCP_REQUEST_LIMIT + 64) + b"\n")
        refused = process.response(None)
        self.assertEqual(refused["error"]["code"], INVALID_REQUEST)
        self.assertEqual(process.result("ping", id="after-oversize"), {})

    def test_blank_lines_and_crlf_are_accepted(self):
        process = initialized_process()
        process.send_raw(b"\n   \n\t\n")
        process.send_raw(_encode({"jsonrpc": "2.0", "id": "crlf", "method": "ping"}) + b"\r\n")
        response = process.response("crlf")
        self.assertEqual(response["result"], {})


class LifecycleTests(unittest.TestCase):
    def test_requests_before_initialize_are_refused_but_ping_works(self):
        process = spawn_process()
        try:
            self.assertEqual(process.result("ping"), {})
            for method in ("tools/list", "tools/call"):
                with self.subTest(method=method):
                    error = process.error(method, {"name": "search", "arguments": {}})
                    self.assertEqual(error["code"], INVALID_REQUEST)
            self.assertEqual(process.error("bogus/method")["code"], METHOD_NOT_FOUND)
            self.assertEqual(process.error("initialize", {"capabilities": {}})["code"],
                             INVALID_PARAMS)
            negotiated = process.initialize()
            self.assertEqual(negotiated["protocolVersion"], PROTOCOL_VERSION)
        finally:
            self.assertEqual(process.close(), 0)

    def test_initialize_requires_identity_and_initialized_notification(self):
        process = spawn_process()
        try:
            for params in (
                    {"protocolVersion": PROTOCOL_VERSION},
                    {"protocolVersion": PROTOCOL_VERSION, "capabilities": None, "clientInfo": []},
                    {"protocolVersion": PROTOCOL_VERSION, "capabilities": {},
                     "clientInfo": {"name": "missing-version"}},
                    {"protocolVersion": PROTOCOL_VERSION, "capabilities": {},
                     "clientInfo": {"name": 7, "version": "1"}}):
                with self.subTest(params=params):
                    self.assertEqual(process.error("initialize", params)["code"], INVALID_PARAMS)
            process.initialize()
            self.assertEqual(process.error("tools/list")["code"], INVALID_REQUEST)
            self.assertEqual(process.error("tools/call", {
                "name": "search", "arguments": {"query": "catalog"}})["code"], INVALID_REQUEST)
            process.notify("notifications/initialized", [])
            self.assertEqual(process.error("tools/list")["code"], INVALID_REQUEST)
            process.mark_initialized()
            self.assertEqual({tool["name"] for tool in process.result("tools/list")["tools"]},
                             set(TOOL_NAMES))
        finally:
            self.assertEqual(process.close(), 0)

    def test_notifications_never_reply(self):
        process = spawn_process()
        try:
            process.notify("notifications/initialized")
            process.notify("notifications/cancelled", {"requestId": 1, "reason": "test"})
            process.notify("notifications/unknown")
            # A response to any notification would be read first and its id
            # would not match this ping id.
            self.assertEqual(process.result("ping", id="after-notifications"), {})
            # The initialized notification before `initialize` did not initialize.
            self.assertEqual(process.error("tools/list")["code"], INVALID_REQUEST)
            process.initialize()
            process.mark_initialized()
            self.assertEqual(process.result("tools/list")["tools"][0]["name"], TOOL_NAMES[0])
        finally:
            self.assertEqual(process.close(), 0)

    def test_eof_is_a_graceful_close_with_no_extra_output(self):
        process = spawn_process()
        process.initialize()
        process.mark_initialized()
        self.assertEqual(process.close(), 0)
        self.assertEqual(process.trailing_messages(), [])
        self.assertIsNotNone(process.process.poll())
        for message in process.seen:
            self.assertEqual(message["jsonrpc"], "2.0")

    def test_unterminated_last_message_is_answered_before_exit(self):
        process = spawn_process()
        process.send_raw(_encode({"jsonrpc": "2.0", "id": "tail", "method": "ping"}))
        # The unterminated line is only a complete message at EOF, so the client
        # must close stdin before the answer can arrive.
        process.close_stdin()
        response = process.response("tail")
        self.assertEqual(response["result"], {})
        self.assertEqual(process.wait(), 0)
        self.assertEqual(process.trailing_messages(), [])


def tearDownModule() -> None:
    global _SHARED
    if _SHARED is None:
        return
    process = _SHARED
    _SHARED = None
    code = process.close()
    leftovers = process.trailing_messages()
    if code != 0 or leftovers:
        raise AssertionError(
            f"shared cjdoc mcp exited with {code} and {len(leftovers)} trailing message(s); "
            f"stderr: {process.stderr_text()[:2000]}")


def configure(binary: Path, snapshots: list[Path], timeout: float) -> None:
    global BINARY, SNAPSHOTS, TIMEOUT
    BINARY = binary
    SNAPSHOTS = tuple(snapshots)
    TIMEOUT = timeout


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--binary", type=Path, required=True,
                        help="compiled cjdoc executable that implements `mcp` and `query`")
    parser.add_argument("--snapshot", type=Path, action="append", required=True,
                        help="Doc IR v16 snapshot or machine manifest (repeatable)")
    parser.add_argument("--timeout", type=float, default=TIMEOUT,
                        help="seconds to wait for one protocol response or process exit")
    known, remaining = parser.parse_known_args(argv)
    configure(known.binary.resolve(), [item.resolve() for item in known.snapshot],
              known.timeout)
    unittest.main(argv=[sys.argv[0], *remaining])


if __name__ == "__main__":
    main()
