#!/usr/bin/env python3
"""Boundary tests for scripts/native_compiler_capture.py.

Only consumer-visible facts are asserted: what activates, what the frontend channel
retains, what is published, what a missing or unsafe input does to the published
record, and that the stage's own exit status survives every one of those decisions.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import native_compiler_capture as capture_module
from native_compiler_capture import NativeCompilerCapture

PRODUCT_REASON = "sts-1.2-doc-ir-gc-no-chir-function-inlining"
WINDOWS_LLC_FAILURE = (
    'warning: unused variable\n'
    'Exception Code: 0xC0000005\n'
    'error: ""D:\\a\\_temp\\setup-cangjie\\third_party\\llvm\\bin\\llc.exe" '
    '"C:\\Users\\RUNNER~1\\AppData\\Local\\Temp\\cangjie-tmp-Q7X\\widget.opt.bc" '
    '"--cangjie-pipeline" "-O2" "--filetype=obj" "-o" '
    '"C:\\Users\\RUNNER~1\\AppData\\Local\\Temp\\cangjie-tmp-Q7X\\widget.o" '
    '": command failed with exit code 3221225477 (use -V to see invocation)\n'
)
CLEAN_LLVM_TEXT = (
    "; ModuleID = '<audit-input>'\n"
    'source_filename = "0-widget"\n'
    'define void @f() { ret void }\n'
)


def fake_opt(text: str):
    """A stand-in for the SDK's `opt.exe -S` that renders fixed LLVM text."""
    def run(command, **_kwargs):
        Path(command[command.index("-o") + 1]).write_text(text, encoding="utf-8")
        return subprocess.CompletedProcess(command, 0, b"", b"")
    return run


class _Fixture:
    """A fake SDK, a runner temp, an evidence dir and a provider stage log."""

    def __init__(self, root: Path, *, ci: bool = False) -> None:
        self.root = root
        self.sdk = root / "sdk"
        for relative in capture_module.SDK_BINARIES:
            binary = self.sdk / relative
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(b"sdk-binary:" + relative.encode())
        self.runner = root / "runner"
        self.runner.mkdir(exist_ok=True)
        self.evidence = root / "evidence"
        self.evidence.mkdir(exist_ok=True)
        self.workspace = root / "workspace"
        self.workspace.mkdir(exist_ok=True)
        self.environment = {
            "RUNNER_TEMP": str(self.runner),
            "CANGJIE_HOME": str(self.sdk),
            "GITHUB_WORKSPACE": str(self.workspace),
        }
        if ci:
            self.environment["GITHUB_ACTIONS"] = "true"
            self.environment["CI"] = "true"

    @property
    def stage_log(self) -> Path:
        return self.evidence / "provider.log"

    def prepare(self) -> NativeCompilerCapture:
        capture = NativeCompilerCapture.prepare(self.evidence, self.environment)
        if not capture.active:
            raise AssertionError(f"fixture preparation failed: {capture.reason} ({capture._detail})")
        return capture

    def write_ir(self, name: str, payload: bytes = b"bitcode") -> Path:
        path = Path(self.environment[capture_module.DIAGNOSTICS_ENV]) / name
        path.write_bytes(payload)
        return path

    def write_invocations(self, *, option: str | None = None, exit_code: int = 5,
                          phase: str = "product-run") -> None:
        diagnostics = self.environment[capture_module.DIAGNOSTICS_ENV]
        record = {
            "package": "provider_plugin_fixture",
            "option": option if option is not None else (
                f'-O2 --fno-chir-function-inlining -V --save-temps "{diagnostics}"'),
            "policySha256": "0" * 64,
            "wrapperSha256": "1" * 64,
            "phase": phase,
            "reason": PRODUCT_REASON,
            "exitCode": exit_code,
            "argv": ["run", "--build-args", "--jobs 1"],
            "binary": None,
            "platform": "windows-x64",
            "workspace": str(self.workspace),
        }
        Path(self.environment[capture_module.INVOCATION_ENV]).write_text(
            json.dumps(record) + "\n", encoding="utf-8", newline="\n")

    def observe_compilations(self, capture: NativeCompilerCapture) -> None:
        capture.observe(
            f"Compiling package `provider_plugin_fixture`: cjc.exe -p "
            f"{self.workspace}/src --output-dir={self.workspace}/target "
            f"--import-path={self.sdk}".encode())
        capture.observe(
            b'""/sdk/bin/cjc-frontend.exe" "--cfg=target=x86_64-w64-mingw32" '
            b'"-o" "widget.bc"')

    def write_log(self, text: str = WINDOWS_LLC_FAILURE) -> None:
        self.stage_log.write_text(text, encoding="utf-8", newline="\n")

    def record(self) -> dict:
        return json.loads((self.evidence / "provider.native-compiler.json").read_text())


class CaptureTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="cjdoc-native-capture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def fixture(self, *, ci: bool = False, name: str = "case") -> _Fixture:
        return _Fixture(self.root / name, ci=ci)

    def assertNoMachinePaths(self, document: dict, fixture: _Fixture) -> None:
        text = json.dumps(document)
        for forbidden in (str(self.root), str(fixture.sdk), str(fixture.runner)):
            self.assertNotIn(forbidden, text)


class PrepareTest(CaptureTestCase):
    def test_prepare_exposes_an_owned_private_diagnostics_root(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        self.assertTrue(capture.active)
        self.assertIsInstance(capture.diagnostics_dir, Path)
        self.assertTrue(capture.diagnostics_dir.is_dir())
        # The compile only gains the diagnostics flags through this channel.
        self.assertEqual(fixture.environment[capture_module.DIAGNOSTICS_ENV],
                         str(capture.diagnostics_dir))
        self.assertEqual(Path(fixture.environment[capture_module.INVOCATION_ENV]).parent,
                         capture.diagnostics_dir.parent)
        if os.name == "posix":
            mode = stat.S_IMODE(capture.diagnostics_dir.parent.stat().st_mode)
            self.assertEqual(mode & 0o077, 0, "scratch root must not be group/world readable")
        self.assertNotEqual(fixture.prepare().diagnostics_dir, capture.diagnostics_dir)

    def test_descriptor_timestamp_semantics_do_not_reject_a_stable_sdk(self) -> None:
        fixture = self.fixture()
        original_fstat = os.fstat

        def descriptor_stat(descriptor):
            observed = original_fstat(descriptor)
            return types.SimpleNamespace(
                st_mode=observed.st_mode, st_dev=observed.st_dev,
                st_ino=observed.st_ino, st_size=observed.st_size,
                st_mtime_ns=observed.st_mtime_ns - 100,
                st_ctime_ns=observed.st_ctime_ns + 17_000_000_000)

        with mock.patch.object(capture_module.os, "fstat", descriptor_stat):
            capture = fixture.prepare()
            fixture.observe_compilations(capture)
            fixture.write_ir("widget.bc", b"stable-ir")
            fixture.write_invocations(exit_code=0)
            record = capture.finish(0, fixture.stage_log)
        self.assertEqual(record["status"], "recorded")
        self.assertTrue(record["sdk"]["matchesPrepare"])
        expected = hashlib.sha256(b"sdk-binary:bin/cjc.exe").hexdigest()
        self.assertEqual(record["sdk"]["binaries"]["bin/cjc.exe"]["sha256"], expected)
        self.assertTrue(record["temporaryRemoved"])

    def test_prepare_that_cannot_promise_evidence_changes_nothing(self) -> None:
        for name, mutate in (
            ("prepare-runner-temp-missing", lambda env: env.pop("RUNNER_TEMP")),
            ("sdk-root-unresolved", lambda env: env.pop("CANGJIE_HOME")),
        ):
            with self.subTest(name=name):
                fixture = self.fixture(name=name)
                mutate(fixture.environment)
                before = dict(fixture.environment)
                capture = NativeCompilerCapture.prepare(fixture.evidence, fixture.environment)
                self.assertFalse(capture.active)
                self.assertEqual(fixture.environment, before)
                record = capture.finish(3, fixture.stage_log)
                self.assertEqual(capture.reason, name)
                self.assertEqual(record["status"], "unavailable")
                self.assertEqual(record["reason"], name)
                self.assertEqual(record["stageExitCode"], 3)
                self.assertIsNone(record["payload"])

    def test_prepare_rejects_an_unsafe_sdk_binary_and_low_free_space(self) -> None:
        fixture = self.fixture(name="unsafe-sdk")
        blocker = fixture.root / "elsewhere.exe"
        blocker.write_bytes(b"other")
        target = fixture.sdk / "bin/cjc.exe"
        if os.name == "posix":
            target.unlink()
            target.symlink_to(blocker)
            capture = NativeCompilerCapture.prepare(fixture.evidence, fixture.environment)
            self.assertFalse(capture.active)
            self.assertEqual(capture.reason, "sdk-inventory-incomplete")
            self.assertIsNone(
                fixture.environment.get(capture_module.DIAGNOSTICS_ENV))

        crowded = self.fixture(name="low-space")
        with mock.patch.object(capture_module.shutil, "disk_usage",
                               return_value=types.SimpleNamespace(total=1, used=1,
                                                                  free=1024)):
            capture = NativeCompilerCapture.prepare(crowded.evidence, crowded.environment)
        self.assertFalse(capture.active)
        self.assertEqual(capture.reason, "prepare-free-space-low")

    def test_prepare_failure_removes_its_own_scratch_root(self) -> None:
        fixture = self.fixture(name="empty-opt")
        # A failing inventory happens after the root exists, so this covers the
        # cleanup path rather than only the early refusals.
        (fixture.sdk / "third_party/llvm/bin/opt.exe").write_bytes(b"")
        capture = NativeCompilerCapture.prepare(fixture.evidence, fixture.environment)
        self.assertFalse(capture.active)
        self.assertEqual(list(fixture.runner.iterdir()), [])


class ObserveTest(CaptureTestCase):
    def test_channel_keeps_only_compiler_commands_and_reports_ownership(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        capture.observe(b"warning: unused variable")
        capture.observe(b"")
        # A later observation on an inactive capture records nothing.
        NativeCompilerCapture(fixture.evidence).observe(b"Compiling package `x`: cjc.exe")

        fixture.write_ir("widget.opt.bc", b"bitcode")
        fixture.write_invocations(exit_code=0)
        fixture.write_log("cjpm run success\n")
        record = capture.finish(0, fixture.stage_log)

        self.assertEqual(record["status"], "recorded")
        commands = record["frontendCommands"]
        self.assertEqual(commands["source"], "stage-stream")
        self.assertEqual(commands["count"], 2)
        self.assertFalse(commands["truncated"])
        self.assertEqual(commands["skipped"], 0)
        self.assertEqual([entry["program"] for entry in commands["entries"]],
                         ["cjc", "cjc-frontend"])
        first = commands["entries"][0]
        self.assertEqual(first["package"], "provider_plugin_fixture")
        self.assertIn("--output-dir=<workspace>/target", first["argv"])
        self.assertIn("--import-path=<sdk>", first["argv"])
        self.assertNotIn(str(fixture.workspace), first["commandLine"])
        self.assertNotIn(str(fixture.sdk), first["commandLine"])
        self.assertNoMachinePaths(fixture.record(), fixture)

    def test_channel_is_bounded_and_says_so(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        # A command longer than the line bound is retained, clipped, and marked.
        with mock.patch.object(capture_module, "COMMAND_LINE_LIMIT", 27):
            capture.observe(b'"cjc-frontend.exe" "-o" "widget.bc"')
        with mock.patch.object(capture_module, "COMMAND_TOTAL_LIMIT", 1):
            capture.observe(b'"cjc-frontend.exe" "-o" "other.bc"')
        fixture.write_ir("widget.opt.bc", b"bitcode")
        fixture.write_invocations(exit_code=0)
        fixture.write_log("cjpm run success\n")
        record = capture.finish(0, fixture.stage_log)
        commands = record["frontendCommands"]
        self.assertTrue(commands["entries"][0]["lineTruncated"])
        self.assertTrue(commands["truncated"])
        self.assertEqual(commands["skipped"], 1)

    def test_unobserved_success_is_missing_evidence_not_a_pass(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.write_ir("widget.opt.bc", b"bitcode")
        fixture.write_invocations(exit_code=0)
        record = capture.finish(0, fixture.stage_log)
        self.assertEqual(record["status"], "unavailable")
        self.assertEqual(record["reason"], "frontend-commands-empty")
        # The stage itself passed; only the evidence is missing.
        self.assertEqual(record["stageExitCode"], 0)


class FailedStageTest(CaptureTestCase):
    def test_failure_keeps_its_exit_code_and_publishes_normalized_evidence(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        original = b"original-bitcode-bytes"
        fixture.write_ir("widget.opt.bc", original)
        fixture.write_ir("widget.o", b"object")
        fixture.write_invocations()
        fixture.write_log()
        with mock.patch.object(capture_module.subprocess, "run",
                               fake_opt(CLEAN_LLVM_TEXT)):
            record = capture.finish(5, fixture.stage_log)

        self.assertEqual(record["status"], "recorded")
        self.assertEqual(record["stageExitCode"], 5)
        self.assertIsNone(record["reason"])
        self.assertEqual(record["sdk"]["matchesPrepare"], True)
        self.assertEqual(sorted(record["sdk"]["binaries"]),
                         sorted(capture_module.SDK_BINARIES))
        self.assertEqual(record["compileOptions"]["product"],
                         ["-O2", "--fno-chir-function-inlining"])
        self.assertEqual(record["compileOptions"]["diagnostics"][:2],
                         ["-V", "--save-temps"])
        self.assertTrue(record["compileOptions"]["diagnosticsDirMatchesCapture"])
        self.assertEqual(record["ir"],
                         {"files": 2, "totalBytes": len(original) + len(b"object")})
        self.assertEqual(record["invocations"]["count"], 1)

        failure = record["compilerFailure"]
        self.assertTrue(failure["observed"])
        self.assertEqual(failure["module"], "widget")
        self.assertEqual(failure["llcExitCode"], 3221225477)
        self.assertEqual(failure["exceptionCode"], "0xC0000005")

        payload = record["payload"]
        self.assertEqual(payload["sha256"], hashlib.sha256(original).hexdigest())
        self.assertEqual(payload["size"], len(original))
        self.assertFalse(payload["rewritten"])
        published = fixture.evidence / payload["file"]
        self.assertEqual(published.read_bytes(), original)
        self.assertTrue(payload["audit"]["moduleIdExcluded"])

        self.assertTrue(record["temporaryRemoved"])
        self.assertFalse(capture.diagnostics_dir.parent.exists())
        self.assertNoMachinePaths(fixture.record(), fixture)

    def test_failure_in_omitted_log_middle_still_selects_the_original_module(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        fixture.write_ir("widget.opt.bc", b"original-failed-module")
        fixture.write_invocations()
        capture.observe(WINDOWS_LLC_FAILURE.encode("utf-8"))
        fixture.write_log("... compiler log middle omitted ...\nfinal compiler summary\n")
        with mock.patch.object(capture_module.subprocess, "run", fake_opt(CLEAN_LLVM_TEXT)):
            record = capture.finish(5, fixture.stage_log)
        self.assertEqual(record["status"], "recorded")
        self.assertEqual(record["compilerFailure"]["source"], "stage-stream")
        self.assertEqual(record["compilerFailure"]["llcExitCode"], 3221225477)
        self.assertEqual((fixture.evidence / record["payload"]["file"]).read_bytes(),
                         b"original-failed-module")

    def test_personal_paths_in_llvm_text_withhold_the_payload(self) -> None:
        for label, text in (
            ("embedded-home",
             ('define void @f()\n'
              '!1 = !DIFile(filename: "x.cj", directory: "C:\\\\Users\\\\example-user\\\\src")\n')),
            ("credential",
             'define void @f()\n!9 = !{!"ghp_abcdefghijklmnopqrstuvwxyz0123"}\n'),
        ):
            with self.subTest(label=label):
                fixture = self.fixture(name=label)
                capture = fixture.prepare()
                fixture.observe_compilations(capture)
                fixture.write_ir("widget.opt.bc", b"bitcode")
                fixture.write_invocations()
                fixture.write_log()
                with mock.patch.object(capture_module.subprocess, "run",
                                       fake_opt(text)):
                    record = capture.finish(5, fixture.stage_log)
                self.assertEqual(record["status"], "unavailable")
                self.assertEqual(record["reason"], "privacy-audit-rejected")
                self.assertEqual(record["stageExitCode"], 5)
                self.assertIsNone(record["payload"])
                self.assertFalse((fixture.evidence / "provider.native-compiler").exists())
                # The metadata a passing run produces is still there.
                self.assertTrue(record["compilerFailure"]["observed"])
                self.assertIsNotNone(record["ir"])
                self.assertNoMachinePaths(fixture.record(), fixture)

    def test_module_id_comment_is_not_payload_content(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        fixture.write_ir("widget.opt.bc", b"bitcode")
        fixture.write_invocations()
        fixture.write_log()
        # `opt -S` names its own input; that comment is not something the module
        # stores, so it must neither pass nor fail the payload by itself.
        text = (f"; ModuleID = '{capture.diagnostics_dir}/audit/widget.opt.bc'\n"
                'define void @f() { ret void }\n')
        with mock.patch.object(capture_module.subprocess, "run", fake_opt(text)):
            record = capture.finish(5, fixture.stage_log)
        self.assertEqual(record["status"], "recorded")
        self.assertIsNotNone(record["payload"])

    def test_runner_roots_are_accepted_only_for_an_authenticated_ci_run(self) -> None:
        text = ('define void @f() { ret void }\n'
                '!1 = !DIFile(filename: "x.cj", directory: "D:\\\\a\\\\cjdoc\\\\src")\n'
                '!2 = !DIFile(filename: "y.cj", directory: '
                '"C:\\\\Users\\\\runneradmin\\\\ws\\\\src")\n')
        outcomes = {}
        for label, ci in (("local", False), ("ci", True)):
            fixture = self.fixture(ci=ci, name=label)
            capture = fixture.prepare()
            fixture.observe_compilations(capture)
            fixture.write_ir("widget.opt.bc", b"bitcode")
            fixture.write_invocations()
            fixture.write_log()
            with mock.patch.object(capture_module.subprocess, "run", fake_opt(text)):
                outcomes[label] = capture.finish(5, fixture.stage_log)
        self.assertEqual(outcomes["local"]["reason"], "privacy-audit-rejected")
        self.assertIsNone(outcomes["local"]["payload"])
        self.assertEqual(outcomes["ci"]["status"], "recorded")
        self.assertGreater(outcomes["ci"]["payload"]["audit"]["ciRootOccurrences"], 0)

        blocked = ('define void @f() { ret void }\n'
                   '!1 = !DIFile(filename: "x.cj", directory: "D:\\\\a\\\\_temp\\\\work")\n')
        fixture = self.fixture(ci=True, name="ci-temp")
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        fixture.write_ir("widget.opt.bc", b"bitcode")
        fixture.write_invocations()
        fixture.write_log()
        with mock.patch.object(capture_module.subprocess, "run", fake_opt(blocked)):
            record = capture.finish(5, fixture.stage_log)
        self.assertEqual(record["reason"], "privacy-audit-rejected")
        self.assertIsNone(record["payload"])

    @unittest.skipUnless(os.name == "posix", "POSIX symlink fixture only")
    def test_symlinked_diagnostics_never_become_evidence(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        target = fixture.write_ir("widget.opt.bc", b"bitcode")
        fixture.write_invocations()
        fixture.write_log()
        outside = self.root / "outside.opt.bc"
        outside.write_bytes(b"bitcode")
        target.unlink()
        target.symlink_to(outside)
        with mock.patch.object(capture_module.subprocess, "run", fake_opt(CLEAN_LLVM_TEXT)):
            record = capture.finish(5, fixture.stage_log)
        self.assertEqual(record["reason"], "ir-unsafe")
        self.assertIsNone(record["payload"])
        self.assertEqual(record["stageExitCode"], 5)
        self.assertFalse((fixture.evidence / "provider.native-compiler").exists())

    def test_oversized_diagnostics_never_become_evidence(self) -> None:
        oversized = self.fixture(name="oversized")
        capture = oversized.prepare()
        oversized.observe_compilations(capture)
        capture.diagnostics_dir.joinpath("widget.opt.bc").write_bytes(b"bitcode")
        oversized.write_invocations()
        oversized.write_log()
        with mock.patch.object(capture_module, "PAYLOAD_LIMIT", 4):
            record = capture.finish(5, oversized.stage_log)
        self.assertEqual(record["reason"], "payload-oversize")
        self.assertIsNone(record["payload"])
        self.assertFalse((oversized.evidence / "provider.native-compiler").exists())
        self.assertEqual(record["stageExitCode"], 5)

    def test_nested_diagnostics_layout_is_refused_and_missing_module_reported(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        (capture.diagnostics_dir / "inner").mkdir()
        fixture.write_invocations()
        fixture.write_log()
        record = capture.finish(5, fixture.stage_log)
        self.assertEqual(record["reason"], "ir-unsafe")
        self.assertEqual(record["reasonDetail"], "inner")
        # A layout this receipt cannot enumerate is reported, not summarised.
        self.assertIsNone(record["ir"])

        missing = self.fixture(name="absent-module")
        capture = missing.prepare()
        missing.observe_compilations(capture)
        missing.write_ir("other.opt.bc", b"bitcode")
        missing.write_invocations()
        missing.write_log()
        record = capture.finish(5, missing.stage_log)
        self.assertEqual(record["reason"], "llc-failure-module-missing")
        self.assertEqual(record["reasonDetail"], "widget.opt.bc")
        self.assertIsNone(record["payload"])


class SuccessTest(CaptureTestCase):
    def test_successful_stage_publishes_metadata_only(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        fixture.write_ir("widget.opt.bc", b"bitcode")
        fixture.write_invocations(exit_code=0)
        fixture.write_log('cjpm run success\n')
        record = capture.finish(0, fixture.stage_log)
        self.assertEqual(record["status"], "recorded")
        self.assertEqual(record["stageExitCode"], 0)
        self.assertIsNone(record["payload"])
        self.assertEqual(record["compilerFailure"], {"observed": False})
        self.assertEqual(record["ir"]["files"], 1)
        self.assertTrue(record["temporaryRemoved"])
        self.assertEqual(sorted(path.name for path in fixture.evidence.iterdir()),
                         ["provider.log", "provider.native-compiler.json"])

    def test_successful_stage_without_diagnostics_is_unavailable(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        fixture.write_invocations(exit_code=0)
        record = capture.finish(0, fixture.stage_log)
        self.assertEqual(record["status"], "unavailable")
        self.assertEqual(record["reason"], "ir-empty")
        self.assertEqual(record["stageExitCode"], 0)

    def test_failure_without_a_backend_line_is_unavailable_but_keeps_the_exit(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        fixture.write_ir("widget.opt.bc", b"bitcode")
        fixture.write_invocations()
        fixture.write_log("error: cjpm run failed\n")
        record = capture.finish(9, fixture.stage_log)
        self.assertEqual(record["reason"], "llc-failure-unrecognized")
        self.assertEqual(record["stageExitCode"], 9)
        self.assertIsNone(record["payload"])
        self.assertIsNotNone(record["sdk"])
        self.assertIsNotNone(record["invocations"])


class EvidenceIntegrityTest(CaptureTestCase):
    def test_metadata_changed_during_copy_is_still_rejected(self) -> None:
        fixture = self.fixture()
        source = fixture.root / "input.bc"
        source.write_bytes(b"stable-input")
        output = fixture.root / "private-copy.bc"
        with output.open("wb") as sink:
            def write_and_change_metadata(block):
                written = sink.write(block)
                observed = source.stat()
                os.utime(source, ns=(observed.st_atime_ns,
                                     observed.st_mtime_ns + 1_000_000_000))
                return written

            with self.assertRaises(capture_module._Unavailable) as failure:
                capture_module._copy_verified(
                    source, types.SimpleNamespace(write=write_and_change_metadata),
                    1024, "input.bc")
        self.assertEqual(failure.exception.reason, "unstable-file")

    def test_changed_sdk_inventory_withholds_the_payload(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        self.assertTrue(capture.active)
        fixture.observe_compilations(capture)
        fixture.write_ir("widget.opt.bc", b"bitcode")
        fixture.write_invocations()
        fixture.write_log()
        (fixture.sdk / "third_party/llvm/bin/llc.exe").write_bytes(b"replaced")
        with mock.patch.object(capture_module.subprocess, "run",
                               side_effect=fake_opt(CLEAN_LLVM_TEXT)) as disassemble:
            record = capture.finish(5, fixture.stage_log)
        self.assertEqual(record["status"], "unavailable")
        self.assertEqual(record["stageExitCode"], 5)
        disassemble.assert_not_called()
        self.assertIsNone(record["payload"])
        self.assertFalse((fixture.evidence / "provider.native-compiler").exists())

    def test_malformed_foreign_or_absent_invocations_are_unavailable(self) -> None:
        for label, payload in (
            ("absent", None),
            ("malformed-json", "{not json}\n"),
            ("unit-only", json.dumps({"phase": "unit-test", "reason": PRODUCT_REASON,
                                      "option": "-O1", "exitCode": 0, "argv": []}) + "\n"),
            ("wrong-reason", json.dumps({"phase": "product-run", "reason": "other",
                                         "option": "-O2", "exitCode": 0,
                                         "argv": []}) + "\n"),
        ):
            with self.subTest(label=label):
                fixture = self.fixture(name=label)
                capture = fixture.prepare()
                fixture.observe_compilations(capture)
                fixture.write_ir("widget.opt.bc", b"bitcode")
                log = Path(fixture.environment[capture_module.INVOCATION_ENV])
                if payload is not None:
                    log.write_text(payload, encoding="utf-8", newline="\n")
                record = capture.finish(5, fixture.stage_log)
                self.assertEqual(record["status"], "unavailable")
                self.assertEqual(record["stageExitCode"], 5)
                self.assertIsNone(record["payload"])
                self.assertTrue(record["reason"].startswith("invocation-log-"))

    def test_other_phases_are_ignored_not_mixed_in(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        fixture.write_ir("widget.opt.bc", b"bitcode")
        fixture.write_invocations(exit_code=0)
        log = Path(fixture.environment[capture_module.INVOCATION_ENV])
        log.write_text(
            json.dumps({"phase": "unit-test", "reason": PRODUCT_REASON, "option": "-O1",
                        "exitCode": 0, "argv": ["test"]}) + "\n" + log.read_text(),
            encoding="utf-8", newline="\n")
        record = capture.finish(0, fixture.stage_log)
        self.assertEqual(record["status"], "recorded")
        self.assertEqual(record["invocations"]["ignored"], 1)
        self.assertEqual(record["invocations"]["count"], 1)

    @unittest.skipUnless(os.name == "posix", "POSIX symlink fixture only")
    def test_an_unsafe_stage_log_is_not_followed(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        fixture.write_ir("widget.opt.bc", b"bitcode")
        fixture.write_invocations()
        outside = self.root / "outside.log"
        outside.write_text(WINDOWS_LLC_FAILURE, encoding="utf-8", newline="\n")
        fixture.stage_log.symlink_to(outside)
        record = capture.finish(5, fixture.stage_log)
        self.assertEqual(record["reason"], "stage-log-missing")
        self.assertEqual(record["stageExitCode"], 5)
        self.assertIsNone(record["payload"])

    def test_existing_evidence_is_never_replaced_or_removed(self) -> None:
        fixture = self.fixture()
        fixture.write_log()
        other = fixture.evidence / "native.log"
        other.write_text("unrelated stage\n", encoding="utf-8", newline="\n")
        sibling = fixture.runner / "someone-elses-work"
        sibling.mkdir()
        (sibling / "keep.txt").write_text("keep", encoding="utf-8")
        receipt = fixture.evidence / "provider.native-compiler.json"
        receipt.write_text('{"status": "previous"}\n', encoding="utf-8", newline="\n")

        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        fixture.write_ir("widget.opt.bc", b"bitcode")
        fixture.write_invocations()
        record = capture.finish(5, fixture.stage_log)

        self.assertEqual(record["status"], "unavailable")
        self.assertEqual(record["reason"], "evidence-exists")
        self.assertEqual(record["stageExitCode"], 5)
        self.assertEqual(receipt.read_text(), '{"status": "previous"}\n')
        self.assertEqual(other.read_text(), "unrelated stage\n")
        self.assertEqual((sibling / "keep.txt").read_text(), "keep")
        self.assertEqual([path.name for path in fixture.runner.iterdir()],
                         ["someone-elses-work"])
        self.assertFalse((fixture.evidence / "provider.native-compiler").exists())

    def test_existing_bitcode_is_not_overwritten(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        fixture.write_ir("widget.opt.bc", b"bitcode")
        fixture.write_invocations()
        fixture.write_log()
        directory = fixture.evidence / "provider.native-compiler"
        directory.mkdir()
        existing = directory / "widget.opt.bc"
        existing.write_bytes(b"previous-artifact")
        with mock.patch.object(capture_module.subprocess, "run",
                               fake_opt(CLEAN_LLVM_TEXT)):
            record = capture.finish(5, fixture.stage_log)
        self.assertEqual(record["reason"], "evidence-exists")
        self.assertEqual(record["reasonDetail"], "widget.opt.bc")
        self.assertEqual(existing.read_bytes(), b"previous-artifact")
        self.assertIsNone(record["payload"])

    def test_symlinked_publication_directory_is_not_adopted(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        fixture.write_ir("widget.opt.bc", b"bitcode")
        fixture.write_invocations()
        fixture.write_log()
        outside = fixture.root / "other-evidence"
        outside.mkdir()
        existing = outside / "widget.opt.bc"
        existing.write_bytes(b"keep-unrelated-evidence")
        directory = fixture.evidence / "provider.native-compiler"
        try:
            directory.symlink_to(outside, target_is_directory=True)
        except OSError:
            self.skipTest("directory symlinks unavailable")
        with mock.patch.object(capture_module.subprocess, "run", fake_opt(CLEAN_LLVM_TEXT)):
            record = capture.finish(5, fixture.stage_log)
        self.assertEqual(record["status"], "unavailable")
        self.assertEqual(record["reason"], "evidence-exists")
        self.assertEqual(existing.read_bytes(), b"keep-unrelated-evidence")
        self.assertEqual(sorted(path.name for path in outside.iterdir()), ["widget.opt.bc"])
        self.assertIsNone(record["payload"])

    def test_input_replaced_between_name_check_and_open_is_not_published(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        source = fixture.write_ir("widget.opt.bc", b"original-snapshot")
        fixture.write_invocations()
        fixture.write_log()
        original_open = os.open
        replaced = False

        def replace_before_open(path, flags, *args, **kwargs):
            nonlocal replaced
            if Path(path) == source and not replaced:
                replaced = True
                source.replace(source.with_suffix(".previous"))
                source.write_bytes(b"replacement-snapshot")
            return original_open(path, flags, *args, **kwargs)

        with mock.patch.object(capture_module.os, "open", replace_before_open):
            record = capture.finish(5, fixture.stage_log)
        self.assertTrue(replaced)
        self.assertEqual(record["status"], "unavailable")
        self.assertEqual(record["reason"], "payload-unreadable")
        self.assertEqual(record["stageExitCode"], 5)
        self.assertIsNone(record["payload"])
        self.assertFalse((fixture.evidence / "provider.native-compiler").exists())

    def test_write_failure_removes_the_published_payload_and_keeps_the_exit(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        fixture.write_ir("widget.opt.bc", b"bitcode")
        fixture.write_invocations()
        fixture.write_log()
        with mock.patch.object(capture_module.subprocess, "run",
                               fake_opt(CLEAN_LLVM_TEXT)), \
                mock.patch.object(NativeCompilerCapture, "_write",
                                  side_effect=capture_module._Unavailable(
                                      "evidence-write-failed")):
            record = capture.finish(5, fixture.stage_log)
        self.assertEqual(record["status"], "unavailable")
        self.assertEqual(record["reason"], "evidence-write-failed")
        self.assertEqual(record["stageExitCode"], 5)
        self.assertIsNone(record["payload"])
        self.assertFalse((fixture.evidence / "provider.native-compiler").exists())
        self.assertTrue(record["temporaryRemoved"])

    def test_repeated_finish_reports_the_first_observation(self) -> None:
        fixture = self.fixture()
        capture = fixture.prepare()
        fixture.observe_compilations(capture)
        fixture.write_ir("widget.opt.bc", b"bitcode")
        fixture.write_invocations()
        fixture.write_log()
        with mock.patch.object(capture_module.subprocess, "run",
                               fake_opt(CLEAN_LLVM_TEXT)):
            first = capture.finish(5, fixture.stage_log)
        payload = fixture.evidence / first["payload"]["file"]
        self.assertTrue(payload.is_file())
        # A second call must not re-publish, delete, or re-decide anything.
        self.assertEqual(capture.finish(5, fixture.stage_log), first)
        self.assertTrue(payload.is_file())


if __name__ == "__main__":
    unittest.main()
