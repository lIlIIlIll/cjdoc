"""Boundary tests for the diagnostic controller; not Windows qualification."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

try:
    from . import windows_codegen_capture as capture
except ImportError:
    import windows_codegen_capture as capture


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cjdoc-codegen-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "checkout"
        (self.source / "src").mkdir(parents=True)
        (self.source / "scripts").mkdir()
        self.manifest = ('[package]\nname = "cjdoc"\noverride-compile-option = ""\n'
                         '[dependencies]\nmarkdown = { commitId = "' + capture.MARKDOWN_COMMIT + '" }\n')
        (self.source / "cjpm.toml").write_text(self.manifest)
        (self.source / "src/api.cj").write_text("package fixture\npublic func api(): Unit {}\n")
        (self.source / "scripts/with_stdx.py").write_text("# authenticated helper fixture\n")
        self.files = ["cjpm.toml", "src/api.cj", "scripts/with_stdx.py"]
        sdk = self.root / "sdk"
        self.bin = sdk / "bin"
        self.bin.mkdir(parents=True)
        self.llvm = sdk / "third_party/llvm/bin"
        self.llvm.mkdir(parents=True)
        for name in ("cjc.exe", "cjpm.exe"):
            path = self.bin / name
            path.write_bytes(b"SDK executable fixture")
            path.chmod(0o755)
        for name in capture.LLVM_FILES + capture.OPTIONAL_LLVM_FILES:
            (self.llvm / name).write_bytes(b"LLVM identity fixture")
        self.home = self.root / "user-profile"
        self.dependency = self.home / ".cjpm/git/markdown" / capture.MARKDOWN_COMMIT
        self.dependency.mkdir(parents=True)
        (self.dependency / "module.cj").write_text("package markdown\n")
        self.environment = {"CANGJIE_HOME": str(sdk), "PATH": str(self.bin),
                            "USERPROFILE": str(self.home), "GITHUB_SHA": "a" * 40,
                            "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1",
                            "CJDOC_STS_INVOCATION_LOG": "must-not-be-appended",
                            "CJDOC_REAL_CJPM": "must-not-be-used"}
        self.out = self.root / "capture"
        self.builds = []
        self.code = 0
        self.fingerprint = capture.FINGERPRINT
        self.source_head = capture.SOURCE_COMMIT
        self.dirty = False
        self.ir_text = 'source_filename = "markdown"\n'
        self.produce_ir = True
        self.mutate_tool = False
        self.mutate_source = False
        self.raw_bc = b"BC\xc0\xde\x00original exact bytes"

    def run_command(self, command, **kwargs):
        if command[0] == "git":
            repository = Path(command[2])
            args = command[3:]
            if args == ["rev-parse", "HEAD"]:
                value = self.source_head if repository == self.source else capture.MARKDOWN_COMMIT
            elif args == ["rev-parse", "HEAD^{tree}"]:
                value = capture.SOURCE_TREE
            elif args == ["diff", "--exit-code", "HEAD", "--"]:
                return subprocess.CompletedProcess(command, int(self.dirty), "", "")
            elif args == ["ls-files", "-z"]:
                files = self.files if repository == self.source else ["module.cj"]
                value = "\0".join(files) + "\0"
            else:
                raise AssertionError(command)
            return subprocess.CompletedProcess(command, 0, value, "")
        if "--print-env" in command:
            values = {"CJDOC_STDX_VARIANT": "static", "CJDOC_STDX_DIGEST": capture.STDX_DIGEST,
                      "CJDOC_TOOLCHAIN_FINGERPRINT": self.fingerprint,
                      "CJDOC_TOOLCHAIN_TARGET": "x86_64-w64-mingw32",
                      "CJDOC_TOOLCHAIN_VERSION": "1.2.0 (cjnative)"}
            return subprocess.CompletedProcess(command, 0, "\n".join(f"{k}={v}" for k, v in values.items()), "")
        if command[1:] == ["-v"]:
            return subprocess.CompletedProcess(command, 0, "SDK 1.2.0 fixture\n", "")
        if Path(command[0]).name == "llvm-dis.exe":
            Path(command[-1]).write_text(self.ir_text)
            return subprocess.CompletedProcess(command, 0, "", "")
        self.assertEqual(command[1:5], ["build", "--jobs", "1", "-V"])
        self.builds.append((command, kwargs))
        for key in ("CJDOC_STS_INVOCATION_LOG", "CJDOC_REAL_CJPM"):
            self.assertNotIn(key, kwargs["env"])
        self.assertEqual(kwargs["env"]["cjHeapSize"], "512MB")
        kwargs["stdout"].write(f"Compiling package `markdown`: cjc -p {self.dependency}/src "
                                 f"{capture.PRODUCT_OPTIONS} -V --save-temps {self.out}/ir\n")
        if self.produce_ir:
            (self.out / "ir/markdown.opt.bc").write_bytes(self.raw_bc)
            (self.out / "ir/unrelated.opt.bc").write_bytes(b"not allowed")
        if self.mutate_source:
            (self.out / "source/src/api.cj").write_text("changed observed source")
        if self.mutate_tool:
            (self.llvm / "llc.exe").write_bytes(b"changed SDK bytes")
        return subprocess.CompletedProcess(command, self.code)

    def execute(self):
        result = capture.Capture(self.source, self.out, self.environment, self.run_command).run()
        receipt = json.loads((self.out / "upload/receipt.json").read_text())
        return result, receipt

    def test_one_build_records_real_argv_and_stages_only_exact_ir(self):
        result, receipt = self.execute()
        self.assertEqual(result, 0)
        self.assertEqual(len(self.builds), 1)
        self.assertEqual(receipt["buildInvocations"], 1)
        self.assertFalse(receipt["qualification"])
        self.assertFalse(receipt["acceptedBaseline"])
        self.assertEqual(receipt["observation"], "NOT_REPRODUCED")
        self.assertFalse(receipt["captureIncomplete"])
        self.assertTrue(receipt["originalSourceUnchanged"])
        self.assertTrue(receipt["privateSourceUnchanged"])
        self.assertEqual(receipt["manifestBeforeSha256"], capture.digest(self.source / "cjpm.toml"))
        self.assertEqual(receipt["rawIr"]["sha256"], capture.digest(self.out / "ir/markdown.opt.bc"))
        self.assertEqual((self.out / "upload/markdown.opt.bc").read_bytes(), self.raw_bc)
        self.assertEqual({p.name for p in (self.out / "upload").iterdir()},
                         {"receipt.json", "tools.json", "argv.json", "build.log", "manifest.diff", "markdown.opt.bc"})
        self.assertEqual((self.source / "cjpm.toml").read_text(), self.manifest)
        observed = (self.out / "source/cjpm.toml").read_text()
        self.assertIn(capture.PRODUCT_OPTIONS + " -V --save-temps", observed)
        self.assertEqual((self.out / "source/src/api.cj").read_bytes(),
                         (self.source / "src/api.cj").read_bytes())
        self.assertNotIn(str(self.root), (self.out / "upload/receipt.json").read_text())

    def test_compiler_failure_is_not_retried_or_masked_by_privacy_failure(self):
        for code in (47, 3221225477):
            with self.subTest(code=code):
                self.out = self.root / f"capture-{code}"
                self.code = code
                self.ir_text = 'source_filename = "C:/Users/alice/private/source.cj"\n'
                result, receipt = self.execute()
                self.assertEqual(result, code)
                self.assertEqual(receipt["buildExitCode"], code)
                self.assertEqual(receipt["buildInvocations"], 1)
                self.assertTrue(receipt["privacyBlocked"])
                self.assertTrue(receipt["captureIncomplete"])
                self.assertFalse((self.out / "upload/markdown.opt.bc").exists())
        self.assertEqual(len(self.builds), 2)

    def test_existing_capture_cannot_start_a_second_build(self):
        self.execute()
        with self.assertRaisesRegex(capture.CaptureError, "already exists"):
            self.execute()
        self.assertEqual(len(self.builds), 1)

    def test_identity_mismatch_stops_before_build_and_writes_receipt(self):
        self.fingerprint = "unexpected"
        result, receipt = self.execute()
        self.assertEqual(result, 2)
        self.assertEqual(self.builds, [])
        self.assertIsNone(receipt["buildExitCode"])
        self.assertEqual(receipt["observation"], "BUILD_NOT_STARTED")
        self.assertIn("identity differs", " ".join(receipt["issues"]))

    def test_wrong_or_dirty_source_cannot_start_build(self):
        self.source_head = "0" * 40
        result, _ = self.execute()
        self.assertEqual(result, 2)
        self.assertFalse(self.builds)
        self.out = self.root / "dirty-capture"
        self.source_head = capture.SOURCE_COMMIT
        self.dirty = True
        result, _ = self.execute()
        self.assertEqual(result, 2)
        self.assertFalse(self.builds)

    def test_missing_ir_is_not_a_successful_capture(self):
        self.produce_ir = False
        result, receipt = self.execute()
        self.assertEqual(result, 2)
        self.assertEqual(receipt["buildExitCode"], 0)
        self.assertTrue(receipt["captureIncomplete"])
        self.assertFalse((self.out / "upload/markdown.opt.bc").exists())

    def test_missing_same_sdk_disassembler_blocks_raw_upload(self):
        (self.llvm / "llvm-dis.exe").unlink()
        result, receipt = self.execute()
        self.assertEqual(result, 2)
        self.assertTrue(receipt["privacyBlocked"])
        self.assertFalse((self.out / "upload/markdown.opt.bc").exists())

    def test_changed_sdk_tool_is_reported_without_overriding_compiler_failure(self):
        self.mutate_tool = True
        self.code = 9
        result, receipt = self.execute()
        self.assertEqual(result, 9)
        self.assertNotEqual(receipt["toolHashesBefore"], receipt["toolHashesAfter"])
        self.assertIn("SDK tool bytes changed", " ".join(receipt["issues"]))

    def test_bitcode_symlink_is_not_uploaded(self):
        self.out.mkdir()
        (self.out / "ir").mkdir()
        (self.out / "raw").mkdir()
        (self.out / "upload").mkdir()
        outside = self.root / "private.opt.bc"
        outside.write_bytes(b"external file")
        try:
            (self.out / "ir/markdown.opt.bc").symlink_to(outside)
        except OSError:
            self.skipTest("symlink creation unavailable")
        value = capture.Capture(self.source, self.out, self.environment, self.run_command)
        self.assertFalse(value.stage_ir())
        self.assertFalse((self.out / "upload/markdown.opt.bc").exists())

    def test_manifest_rejects_wrong_pin_and_ambiguous_path(self):
        with self.assertRaises(capture.CaptureError):
            capture.instrument_manifest(self.manifest.replace(capture.MARKDOWN_COMMIT, "wrong"), self.root / "ir")
        with self.assertRaises(capture.CaptureError):
            capture.instrument_manifest(self.manifest, self.root / "has space")

    def test_private_network_and_host_identifiers_block_raw_ir(self):
        for text in ('source_filename = "10.1.2.3"', 'source_filename = "internal.example"',
                     'source_filename = "/data/private/file.cj"'):
            environment = {"USERDNSDOMAIN": "internal.example"}
            self.assertTrue(capture.private_reasons(text, environment))

    def test_missing_sdk_home_is_a_recorded_prebuild_failure(self):
        self.environment.pop("CANGJIE_HOME")
        result, receipt = self.execute()
        self.assertEqual(result, 2)
        self.assertEqual(receipt["buildInvocations"], 0)
        self.assertIn("SDK home is unavailable", " ".join(receipt["issues"]))

    def test_observed_source_mutation_cannot_be_a_successful_capture(self):
        self.mutate_source = True
        result, receipt = self.execute()
        self.assertEqual(result, 2)
        self.assertFalse(receipt["privateSourceUnchanged"])
        self.assertEqual(len(self.builds), 1)

    def test_required_llvm_tool_missing_prevents_any_build(self):
        (self.llvm / "llc.exe").unlink()
        result, receipt = self.execute()
        self.assertEqual(result, 2)
        self.assertEqual(receipt["buildInvocations"], 0)
        self.assertEqual(self.builds, [])

    def test_text_and_receipt_fail_closed_for_unknown_private_content(self):
        value = capture.Capture(self.source, self.out, self.environment)
        self.out.mkdir()
        (self.out / "upload").mkdir()
        value.publish("build.log", "unknown C:/Users/alice/secret.txt")
        self.assertTrue(value.record["privacyBlocked"])
        self.assertNotIn("alice", (self.out / "upload/build.log").read_text())
        public = value.public_record({"error": "github_pat_" + "a" * 30, "buildExitCode": 47})
        self.assertEqual(public, {"error": "<privacy-blocked>", "buildExitCode": 47})


class WorkflowTests(unittest.TestCase):
    def test_diagnostic_has_no_required_or_release_paths(self):
        path = Path(__file__).resolve().parent.parent / ".github/workflows/ci.yml"
        text = path.read_text()
        self.assertIn("workflow_dispatch:", text)
        self.assertNotIn("pull_request:", text)
        self.assertNotIn("push:", text)
        self.assertNotIn("CI required", text)
        self.assertNotIn("scripts/check.sh", text)
        self.assertNotIn("CJDOC_STS_INVOCATION_LOG", text)
        self.assertIn("ref: " + capture.SOURCE_COMMIT, text)
        self.assertNotIn("**", text)
        self.assertEqual(text.count("python control/scripts/windows_codegen_capture.py"), 1)
        for name in ("receipt.json", "tools.json", "build.log", "argv.json", "manifest.diff", "markdown.opt.bc"):
            self.assertIn("/upload/" + name, text)


if __name__ == "__main__":
    unittest.main()
