#!/usr/bin/env python3
"""One frozen fixture command with reviewed diagnostic publication."""
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
    source_commit = "8cc8f71a296b1c6321e575b56fadbd0c379e242a"
    source_tree = "8bc115f09ed8823cdbe8dd66fdd940bf29b35af8"
    diagnostic_scope = "only public-cancel-host build; original 1200-second bound"
    status_prefix = "HOST_BUILD"

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

    def prepare_target(self, source, shell):
        pass

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
        self.prepare_target(source, shell)
        command = self.host_command(shell)
        bounded = [sys.executable, str(self.source / "scripts/run_with_timeout.py"),
                   "1200", "--", *command]
        self.evidence.update({"targetInvocations": 1, "targetCommand": command,
                              "sourceArchiveSha256": digest(archive),
                              "diagnosticScope": self.diagnostic_scope,
                              "qualification": "diagnostic only; fresh controlled temporary paths",
                              "backendTrace": {"backendInvocations": 0, "reason": "not requested"}})
        result = self.call("target", bounded, cwd=source, checked=False)
        self.build_log += result.stdout + result.stderr
        self.exit_code = result.returncode
        self.evidence["processExitCode"] = result.returncode
        self.evidence["status"] = self.status_prefix + ("_FAILED" if result.returncode else "_SUCCEEDED")
        after = inventory(source, names)
        self.evidence["archiveTrackedSourcesUnchanged"] = after == before
        if after != before:
            raise ValueError("host build changed a tracked archive input")
        receipt = self.private / "sts-invocations.jsonl"
        if receipt.is_file():
            self.evidence["stsInvocations"] = [json.loads(line) for line in receipt.read_text().splitlines()]


class RootBuildAttempt(HostBuildAttempt):
    diagnostic_scope = "one original Windows root CLI build; 1200-second bound; no IR or backend observation"
    status_prefix = "ROOT_BUILD"

    def host_command(self, shell):
        return [shell, "--noprofile", "--norc", "-c",
                '. scripts/with_sts_cjpm.sh; cjpm build --jobs 1']


class ProviderBuildAttempt(HostBuildAttempt):
    diagnostic_scope = "one root CLI prerequisite build then one provider run; each bounded at 1200 seconds; no backend observation"
    status_prefix = "PROVIDER_RUN"

    def prepare_target(self, source, shell):
        # The fixture explicitly invokes ../../../../target/release/bin/main.
        # A static path dependency does not provide that root CLI executable.
        command = [shell, "--noprofile", "--norc", "-c",
                   '. scripts/with_sts_cjpm.sh; cjpm build --jobs 1']
        bounded = [sys.executable, str(self.source / "scripts/run_with_timeout.py"),
                   "1200", "--", *command]
        self.evidence["prerequisiteInvocations"] = 1
        result = self.call("prerequisite-root", bounded, cwd=source, checked=False)
        self.evidence["prerequisiteExitCode"] = result.returncode
        self.build_log = result.stdout + result.stderr
        if result.returncode:
            self.exit_code = result.returncode
            self.evidence["firstChildFailureExitCode"] = result.returncode
        names = [row["path"] for row in self.evidence["sourceBefore"]["files"]]
        unchanged = inventory(source, names) == self.evidence["sourceBefore"]["files"]
        self.evidence["prerequisiteTrackedSourcesUnchanged"] = unchanged
        if not unchanged:
            raise ValueError("prerequisite changed a tracked archive input")
        if result.returncode:
            raise capture.ChildFailed("prerequisite-root", result.returncode)
        candidates = [source / "target/release/bin" / name for name in ("main", "main.exe")]
        binary = next((path for path in candidates if path.is_file() and not path.is_symlink()), None)
        if binary is None:
            raise ValueError("root CLI prerequisite did not produce its executable")
        self.evidence["prerequisiteBinary"] = {"sha256": digest(binary), "bytes": binary.stat().st_size}

    def host_command(self, shell):
        # The exact check.sh provider invocation; no verbose or compiler flag change.
        return [shell, "--noprofile", "--norc", "-c",
                '. scripts/with_sts_cjpm.sh; cd tests/fixtures/projects/provider_plugin; '
                'cjpm run --build-args "--jobs 1"']


PROFILES = {
    "macos-host": (HostBuildAttempt, "macos-arm64"),
    "windows-provider": (ProviderBuildAttempt, "windows-x64"),
    "windows-root-main": (RootBuildAttempt, "windows-x64"),
    "macos-provider-main": (ProviderBuildAttempt, "macos-arm64"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profile", choices=tuple(PROFILES), default="macos-host")
    args = parser.parse_args()
    args.output.mkdir(mode=0o700, exist_ok=False)
    attempt, platform = PROFILES[args.profile]
    return attempt(args.source, args.output, platform).execute()


if __name__ == "__main__":
    raise SystemExit(main())
