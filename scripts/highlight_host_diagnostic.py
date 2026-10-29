#!/usr/bin/env python3
"""One frozen macOS cancellation-host build; no worker run or qualification."""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

import native_codegen_capture as capture
from native_capture_support import digest, inventory

# PR #168 failure: the optional-worker gate reached this exact host-build step.
class HostBuildAttempt(capture.Attempt):
    source_commit = "04ce974e94fc15df3be72ebaeffe1ac0587f9ecb"
    source_tree = "343e41e7b4bb06c23703669f5a6b591497f4b4b9"

    def preflight(self):
        # This profile captures only text from the original host build. Its SDK,
        # source, and dependency checks run in execute; IR capture is out of scope.
        self.evidence["capturePreflight"] = {"status": "NOT_APPLICABLE",
            "reason": "log-only host diagnostic; no extra compiler or IR observation"}

    def identity(self):
        result = super().identity()
        root = Path(__file__).resolve().parents[1]
        result["hostDiagnosticFiles"] = inventory(root, [
            "scripts/highlight_host_diagnostic.py", "scripts/test_highlight_host_diagnostic.py",
            ".github/workflows/highlight-host-diagnostic.yml"])
        return result

    def host_command(self, shell):
        spec = importlib.util.spec_from_file_location(
            "frozen_highlight_ci", self.source / "scripts/highlight_ci.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.public_cancel_host_command(Path(shell))

    def target(self):
        # The real gate builds a tracked archive, not the original Git checkout.
        archive = self.private / "source.tar"
        self.call("tracked-source", ["git", "-C", str(self.source), "archive", "--format=tar",
                  "--output", str(archive), self.source_commit])
        source = self.private / "source"
        source.mkdir(mode=0o700)
        with tarfile.open(archive) as bundle:
            for member in bundle:
                path = Path(member.name)
                if path.is_absolute() or ".." in path.parts or not (member.isfile() or member.isdir()):
                    raise ValueError("unsupported archive member")
            bundle.extractall(source, filter="data")
        names = [row["path"] for row in self.evidence["sourceBefore"]["files"]]
        before = inventory(source, names)
        if before != self.evidence["sourceBefore"]["files"]:
            raise ValueError("tracked archive differs from frozen working source")
        shell = shutil.which("bash", path=self.environment["PATH"])
        if shell is None:
            raise ValueError("native Bash unavailable")
        self.mappings.extend([(source, "<source-copy>"), (Path(shell), "<bash>"),
                              (Path(shell).resolve(), "<bash>")])
        self.environment.update({"GITHUB_WORKSPACE": str(source),
                                 "CJDOC_HIGHLIGHT_BUILD": str(self.private / "host-build")})
        command = self.host_command(shell)
        bounded = [sys.executable, str(self.source / "scripts/run_with_timeout.py"),
                   "1200", "--", *command]
        self.evidence.update({"targetInvocations": 1, "targetCommand": command,
                              "sourceArchiveSha256": digest(archive),
                              "diagnosticScope": "only public-cancel-host build; original 1200-second bound",
                              "qualification": "diagnostic only; fresh controlled temporary paths",
                              "backendTrace": {"backendInvocations": 0, "reason": "not requested"}})
        result = self.call("target", bounded, cwd=source, checked=False)
        self.build_log = result.stdout + result.stderr
        self.exit_code = result.returncode
        self.evidence["processExitCode"] = result.returncode
        self.evidence["status"] = "HOST_BUILD_FAILED" if result.returncode else "HOST_BUILD_SUCCEEDED"
        after = inventory(source, names)
        self.evidence["archiveTrackedSourcesUnchanged"] = after == before
        if after != before:
            raise ValueError("host build changed a tracked archive input")
        receipt = self.private / "sts-invocations.jsonl"
        if receipt.is_file():
            self.evidence["stsInvocations"] = [json.loads(line) for line in receipt.read_text().splitlines()]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(mode=0o700, exist_ok=False)
    return HostBuildAttempt(args.source, args.output, "macos-arm64").execute()


if __name__ == "__main__":
    raise SystemExit(main())
