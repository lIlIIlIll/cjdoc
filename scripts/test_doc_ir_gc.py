"""Exercise the O2 Doc IR consumer with frequent GC in real CLI/MCP processes."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY: Path | None = None
SNAPSHOT: Path | None = None


class DocIrGcProcessTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        assert BINARY is not None and SNAPSHOT is not None
        cls.binary = BINARY
        cls.snapshot = SNAPSHOT
        cls.binary_digest = hashlib.sha256(BINARY.read_bytes()).hexdigest()
        cls.snapshot_digest = hashlib.sha256(SNAPSHOT.read_bytes()).hexdigest()
        print(f"binarySha256={cls.binary_digest} snapshotSha256={cls.snapshot_digest}", file=sys.stderr)
        cls.model = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
        cls.symbol_id = next(s["id"] for s in cls.model["declarations"]
                             if s["visibility"] == "public" and s["ownerId"] is None)
        cls.environment = dict(os.environ, cjHeapSize="2GB", cjGCThreshold="1MB", cjGCInterval="1ms")

    @classmethod
    def tearDownClass(cls) -> None:
        if hashlib.sha256(cls.binary.read_bytes()).hexdigest() != cls.binary_digest:
            raise AssertionError("GC regression binary changed while the cases ran")
        if hashlib.sha256(cls.snapshot.read_bytes()).hexdigest() != cls.snapshot_digest:
            raise AssertionError("GC regression snapshot changed while the cases ran")

    def run_process(self, arguments: list[str], text: str) -> subprocess.CompletedProcess:
        return subprocess.run([str(self.binary), *arguments], input=text, text=True, encoding="utf-8",
                              capture_output=True, env=self.environment, timeout=120)

    def test_query_reads_valid_snapshot_under_frequent_gc(self) -> None:
        request = {"operation": "search", "symbolId": self.symbol_id, "limit": 1}
        for _ in range(2):
            result = self.run_process(["query", "--snapshot", str(self.snapshot),
                                       "--request", "-"], json.dumps(request))
            self.assertEqual(result.returncode, 0, result.stderr)
            document = json.loads(result.stdout)
            self.assertEqual(document["status"], "ok")
            self.assertEqual(len(document["result"]["items"]), 1)
            self.assertEqual(document["result"]["items"][0]["identity"]["symbolId"], self.symbol_id)

    def test_stdio_mcp_reads_same_snapshot_under_frequent_gc(self) -> None:
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "doc-ir-gc-test", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
                "name": "search", "arguments": {"symbolId": self.symbol_id, "limit": 1}}},
        ]
        text = "".join(json.dumps(message) + "\n" for message in messages)
        for _ in range(2):
            result = self.run_process(["mcp", "--snapshot", str(self.snapshot)], text)
            self.assertEqual(result.returncode, 0, result.stderr)
            replies = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual([reply["id"] for reply in replies], [1, 2])
            tool = replies[1]["result"]
            self.assertFalse(tool["isError"])
            self.assertEqual(tool["structuredContent"]["status"], "ok")
            self.assertEqual(len(tool["structuredContent"]["result"]["items"]), 1)
            self.assertEqual(tool["structuredContent"]["result"]["items"][0]["identity"]["symbolId"], self.symbol_id)

    def test_duplicate_fields_and_invalid_model_remain_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="cjdoc-gc-invalid-") as directory:
            path = Path(directory).resolve() / "invalid.json"
            original = self.snapshot.read_text(encoding="utf-8")
            duplicate = original.replace('"schemaVersion":', '"schemaVersion":"duplicate", "schemaVersion":', 1)
            invalid = dict(self.model, status="invalid-model-state")
            cases = ((duplicate, 3, "unavailable", "snapshot_io"),
                     (json.dumps(invalid), 2, "invalid_request", "read_command_input"))
            for content, exit_code, status, error_code in cases:
                path.write_text(content, encoding="utf-8")
                result = self.run_process(["query", "--snapshot", str(path),
                                           "--request", "-"], json.dumps({"operation": "search", "symbolId": self.symbol_id}))
                self.assertEqual(result.returncode, exit_code, result.stderr)
                response = json.loads(result.stdout)
                self.assertEqual(response["status"], status)
                self.assertEqual(response["error"]["code"], error_code)


def setUpModule() -> None:
    if BINARY is None or SNAPSHOT is None:
        raise unittest.SkipTest("scripts/check.sh cli supplies the O2 binary and valid basic Doc IR")


def main() -> None:
    global BINARY, SNAPSHOT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--snapshot", type=Path, required=True)
    arguments, remaining = parser.parse_known_args()
    BINARY = arguments.binary.resolve()
    SNAPSHOT = arguments.snapshot.resolve()
    unittest.main(argv=[sys.argv[0], *remaining])


if __name__ == "__main__":
    main()
