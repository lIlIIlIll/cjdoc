#!/usr/bin/env python3
"""Exercise the optional pinned highlight adapter through real process pipes."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "tools" / "highlight" / "adapter.mjs"
PROTOCOL = "cjdoc-highlight/1"


def request(identifier, code="print(42)\n", language="python"):
    return {"protocol": PROTOCOL, "id": identifier, "language": language, "code": code}


PINNED_DEPENDENCY = ROOT / "tools" / "highlight" / "node_modules" / "highlight.js"


def adapter_dependencies_installed():
    """The adapter runs only after its pinned dependency is provisioned offline.

    Ordinary repository gates must not install packages or touch the network, so
    these cases are skipped until `tools/highlight` has been provisioned from its
    lockfile (see tools/highlight/README.md). Skipping keeps the check honest:
    a missing dependency is reported as unverified rather than as a pass.
    """
    return shutil.which("node") is not None and PINNED_DEPENDENCY.is_dir()


@unittest.skipUnless(adapter_dependencies_installed(),
    "Node.js and the pinned highlight.js dependency must be provisioned offline")

class HighlightAdapterTest(unittest.TestCase):
    def start_worker(self):
        worker = subprocess.Popen([shutil.which("node"), str(ADAPTER)], cwd=ROOT,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, encoding="utf-8")
        self.addCleanup(self.stop_worker, worker)
        return worker

    @staticmethod
    def stop_worker(worker):
        if worker.poll() is None:
            worker.terminate()
            try:
                worker.wait(timeout=5)
            except subprocess.TimeoutExpired:
                worker.kill()
                worker.wait(timeout=5)
        for stream in (worker.stdin, worker.stdout, worker.stderr):
            stream.close()

    def exchange(self, worker, value):
        worker.stdin.write(json.dumps(value, ensure_ascii=False) + "\n")
        worker.stdin.flush()
        return json.loads(worker.stdout.readline())

    def test_start_stop_and_serial_requests(self):
        worker = self.start_worker()
        for identifier in range(10):
            code = 'print("你好😀") # ' + str(identifier) + "\n"
            response = self.exchange(worker, request(identifier, code))
            self.assertEqual(response["id"], identifier)
            self.assertEqual(response["state"], "complete")
            self.assertEqual(response["sourceHash"], hashlib.sha256(code.encode()).hexdigest())
        worker.stdin.close()
        self.assertEqual(worker.wait(timeout=5), 0)
        self.assertEqual(worker.stdout.read(), "")
        self.assertEqual(worker.stderr.read(), "")
        self.assertIsNotNone(worker.poll())

    def test_batched_requests_preserve_order(self):
        values = [request(index, language="json", code='{"x":42}') for index in range(20)]
        result = subprocess.run([shutil.which("node"), str(ADAPTER)], cwd=ROOT,
                                input="".join(json.dumps(value) + "\n" for value in values),
                                text=True, encoding="utf-8", capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([value["id"] for value in responses], list(range(20)))
        self.assertTrue(all(value["protocol"] == PROTOCOL for value in responses))

    def test_malformed_line_is_typed_and_does_not_echo_code(self):
        result = subprocess.run([shutil.which("node"), str(ADAPTER)], cwd=ROOT,
                                input='{"secret-code": broken}\n' + json.dumps(request(2)) + "\n",
                                text=True, encoding="utf-8", capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 2)
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(responses[0]["reason"], "malformed-json")
        self.assertEqual(responses[1]["id"], 2)
        self.assertLess(len(result.stderr), 161)
        self.assertNotIn("secret-code", result.stderr)

    def test_oversized_code_keeps_actual_byte_length(self):
        code = "你" * 100000
        worker = self.start_worker()
        response = self.exchange(worker, request("large", code))
        self.assertEqual(response["reason"], "resource-limit")
        self.assertEqual(response["byteLength"], len(code.encode()))
        self.assertEqual(response["sourceHash"], hashlib.sha256(code.encode()).hexdigest())
        self.assertEqual(response["spans"], [])
        worker.stdin.close()
        self.assertEqual(worker.wait(timeout=5), 0)

    def test_oversized_wire_line_recovers_without_orphan(self):
        result = subprocess.run([shutil.which("node"), str(ADAPTER)], cwd=ROOT,
                                input="x" * (2097152 + 1) + "\n" + json.dumps(request(3)) + "\n",
                                text=True, encoding="utf-8", capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 2)
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(responses[0]["reason"], "resource-limit")
        self.assertIsNone(responses[0]["id"])
        self.assertEqual(responses[1]["id"], 3)
        self.assertLess(len(result.stderr), 161)


if __name__ == "__main__":
    unittest.main()
