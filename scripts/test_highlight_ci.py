"""Fail-closed CI inputs, public failure evidence and real process observations."""
from __future__ import annotations

import contextlib
import io
import json
import os

from pathlib import Path, PureWindowsPath
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci_changes
import highlight_ci
import highlight_process

from highlight_process import (ObservedProcess, assert_stopped, observe_cancel_targets,
                               cleanup_observed, _darwin_executable)

REPO = Path(__file__).resolve().parents[1]


class HighlightCiContractTest(unittest.TestCase):


    def test_ci_change_routes_through_all_required_native_jobs(self):
        plan = ci_changes.classify_paths(["scripts/highlight_ci.py", ".github/workflows/ci.yml"])
        self.assertTrue(plan["native"])
        self.assertTrue(all(plan["jobSet"].values()))

    def test_exact_node_and_lock_versions_fail_closed(self):
        highlight_ci.require_versions(REPO, "v26.11.1\n")
        with self.assertRaises(ValueError):
            highlight_ci.require_versions(REPO, "v26.10.0")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "tools/highlight"
            target.mkdir(parents=True)
            (target / "package.json").write_text(json.dumps({"dependencies": {"highlight.js": "latest"}}))
            (target / "package-lock.json").write_text(json.dumps({"packages": {
                "node_modules/highlight.js": {"version": "11.11.1"}}}))
            with self.assertRaises(ValueError):
                highlight_ci.require_versions(root, "v26.11.1")

    def test_work_root_cannot_pollute_source_or_reuse_existing_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            repo = base / "repo"
            repo.mkdir()
            with self.assertRaises(ValueError):
                highlight_ci.private_directory(repo / "node_modules", repo)
            work = highlight_ci.private_directory(base / "work", repo)
            self.assertTrue(work.is_dir())
            if os.name != "nt":
                self.assertEqual(work.stat().st_mode & 0o777, 0o700)
            with self.assertRaises(FileExistsError):
                highlight_ci.private_directory(work, repo)

    def test_public_failure_facts_never_publish_timeout_argv_or_stderr(self):
        private = PureWindowsPath(r"C:\Users\example-user\workspace")
        command = [str(private / "source/scripts/highlight_acceptance.py"), "credential=secret"]
        timeout = subprocess.TimeoutExpired(command, 600, output=b"private stdout", stderr=b"secret")
        self.assertEqual(highlight_ci.failure_facts(timeout),
                         {"reason": "step-timeout", "timeoutSeconds": 600})
        failed = subprocess.CalledProcessError(7, command, output=b"private stdout", stderr=b"secret")
        self.assertEqual(highlight_ci.failure_facts(failed), {"reason": "step-failed", "exitCode": 7})
        for error in [timeout, failed, PermissionError(13, "secret", str(private)),
                      ValueError(str(timeout))]:
            published = json.dumps(highlight_ci.failure_facts(error))
            for forbidden in ["example-user", "workspace", "secret", "stdout", "highlight_acceptance"]:
                self.assertNotIn(forbidden, published)

    def test_timeout_artifacts_and_console_exclude_private_error_text(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            repo = base / "repo"
            repo.mkdir()
            evidence = base / "evidence"
            command = [str(PureWindowsPath(r"C:\Users\example-user\workspace\secret.py"))]
            private = str(subprocess.TimeoutExpired(command, 600)) + " credential=secret"
            def expire(_command, **options):
                options["stdout"].write(private.encode("utf-8"))
                raise subprocess.TimeoutExpired(command, 600, stderr=b"secret")
            argv = ["highlight_ci.py", "--repo", str(repo), "--binary", str(base / "main"),
                    "--identity", str(base / "manifest.json"), "--platform",
                    highlight_ci.PLATFORMS[(sys.platform, highlight_ci.platform.machine().lower())],
                    "--work-root", str(base / "work"), "--evidence-root", str(evidence)]
            console = io.StringIO()
            with patch.object(sys, "argv", argv), patch.dict(os.environ, {
                    "CJDOC_STDX_PATH": str(base / "stdx"), "CJDOC_STDX_DIGEST": "verified-test-digest"}), \
                    patch("highlight_ci.shutil.which", return_value=sys.executable), \
                    patch("highlight_ci.subprocess.run", side_effect=expire), \
                    contextlib.redirect_stdout(console), contextlib.redirect_stderr(console):
                self.assertEqual(highlight_ci.main(), 1)
            published = console.getvalue() + "".join(path.read_text(encoding="utf-8")
                                                     for path in evidence.iterdir())
            for forbidden in ["example-user", "workspace", "secret", "Users", "stderr", "argv"]:
                self.assertNotIn(forbidden, published)
            identity = json.loads((evidence / "identity.json").read_text(encoding="utf-8"))
            self.assertEqual(identity["status"], "failed")
            self.assertEqual(identity["reason"], "step-timeout")
            self.assertEqual(identity["timeoutSeconds"], 600)
            self.assertEqual(identity["steps"][0]["name"], "node-version")
            self.assertEqual((base / "work/node-version.raw.log").read_text(encoding="utf-8"), private)

    def test_real_traceback_publishes_only_trusted_fault_location(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "source"
            source.mkdir()
            invocation = source
            if os.name != "nt":
                invocation = base / "source-alias"
                invocation.symlink_to(source, target_is_directory=True)
            trusted = invocation / "scripts/highlight_acceptance.py"
            outside = base / "outside/scripts/highlight_acceptance.py"
            trusted.parent.mkdir(parents=True)
            outside.parent.mkdir(parents=True)
            outside.write_text('raise RuntimeError("unpublished fixture prose")\n', encoding="utf-8")
            trusted.write_text(
                "import json, runpy, sys\n"
                "from pathlib import Path\n"
                "from highlight_ci import traceback_locations\n"
                "try:\n"
                "    runpy.run_path(sys.argv[1])\n"
                "except Exception as error:\n"
                "    print(json.dumps(traceback_locations(Path(__file__).resolve().parents[1], error.__traceback__)))\n",
                encoding="utf-8")
            environment = dict(os.environ, PYTHONPATH=str(REPO / "scripts"),
                               PYTHONDONTWRITEBYTECODE="1", PRIVATE_FIXTURE_VALUE="unpublished environment")
            result = subprocess.run([sys.executable, str(trusted), str(outside), "unpublished argument"],
                                    env=environment, capture_output=True, text=True, check=True, timeout=10)
            locations = json.loads(result.stdout)
            self.assertEqual(locations, [{"script": "scripts/highlight_acceptance.py", "line": 5}])
            for forbidden in [str(base), "unpublished", "RuntimeError", "PRIVATE_FIXTURE_VALUE"]:
                self.assertNotIn(forbidden, result.stdout)
            record = base / "locations.json"
            record.write_text(result.stdout, encoding="utf-8")
            self.assertEqual(highlight_ci.load_traceback_locations(record), locations)

    def test_forged_or_oversized_failure_records_are_not_published(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "locations.json"
            valid = {"script": "scripts/highlight_acceptance.py", "line": 5}
            invalid = [
                [{**valid, "script": ["scripts/highlight_acceptance.py"]}],
                [{**valid, "script": "../outside.py"}],
                [{**valid, "line": True}],
                [{**valid, "message": "unpublished fixture prose"}],
                [valid] * 17,
            ]
            for value in invalid:
                with self.subTest(value=value):
                    path.write_text(json.dumps(value), encoding="utf-8")
                    self.assertIsNone(highlight_ci.load_traceback_locations(path))
            path.write_text(json.dumps([valid]) + " " * 8193, encoding="utf-8")
            self.assertIsNone(highlight_ci.load_traceback_locations(path))




class HighlightObservedProcessTest(unittest.TestCase):
    @contextlib.contextmanager
    def live_python(self):
        # Popen returning proves only the first exec completed. Framework Python
        # on macOS subsequently execs its real interpreter and replaces argv[0].
        child = subprocess.Popen([sys.executable, "-c",
            "import time; print('ready', flush=True); time.sleep(60)"],
            stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline(), "ready\n")
            yield child
        finally:
            if child.poll() is None:
                child.kill(); child.wait(timeout=5)
            child.stdout.close()

    def test_real_live_process_is_not_stopped_and_cleanup_uses_its_observation(self):
        observed = None
        # sys.executable can name the framework launcher, not the running image.
        executable = _darwin_executable(os.getpid()) if sys.platform == "darwin" else Path(sys.executable)
        with self.live_python() as child:
            try:
                observed = ObservedProcess(child.pid, require_live=True, expected_executable=executable,
                                           expected_command="-c", expected_parent=os.getpid())
                self.assertFalse(observed.stopped())
                with self.assertRaises(AssertionError):
                    assert_stopped(child.pid, observed)
                observed.cleanup()
                child.wait(timeout=5)
                assert_stopped(child.pid, observed)
            finally:
                if observed:
                    observed.close()

    def test_unexpected_executable_is_not_adopted_or_signalled(self):
        with self.live_python() as child:
            with tempfile.TemporaryDirectory() as temporary:
                other = Path(temporary) / "other-image"
                other.write_bytes(b"not the child image")
                with self.assertRaises(AssertionError):
                    ObservedProcess(child.pid, require_live=True, expected_executable=other)
                self.assertIsNone(child.poll())

    def test_real_exited_process_cannot_be_used_as_a_live_cancel_target(self):
        child = subprocess.Popen([sys.executable, "-c", "pass"])
        child.wait(timeout=5)
        assert_stopped(child.pid)
        with self.assertRaises(AssertionError):
            ObservedProcess(child.pid, require_live=True)

    def test_query_errors_are_not_silent_stopped_results(self):
        target = "highlight_process._windows_api" if os.name == "nt" else "highlight_process._posix_state"
        with patch(target, side_effect=PermissionError("query denied")):
            with self.assertRaises(PermissionError):
                assert_stopped(os.getpid())

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux procfs read boundary")
    def test_read_time_disappearance_is_gone_but_permission_failure_is_not(self):
        with patch("highlight_process.Path.read_text", side_effect=ProcessLookupError("gone during read")):
            observed = ObservedProcess(os.getpid())
            try:
                self.assertTrue(observed.stopped())
                with self.assertRaises(AssertionError):
                    ObservedProcess(os.getpid(), require_live=True)
            finally:
                observed.close()
        with patch("highlight_process.Path.read_text", side_effect=PermissionError("query denied")):
            with self.assertRaises(PermissionError):
                ObservedProcess(os.getpid())

    @unittest.skipUnless(os.name == "nt", "Native Windows retained-handle exit race")
    def test_cleanup_accepts_exit_race_only_when_the_same_handle_is_stopped(self):
        with self.live_python() as child:
            observed = ObservedProcess(child.pid, require_live=True)
            ctypes, types, kernel = highlight_process._windows_api()
            termination = {}
            class ExitRaceKernel:
                def __getattr__(self, name):
                    return getattr(kernel, name)
                def TerminateProcess(self, handle, status):
                    child.terminate()
                    child.wait(timeout=5)
                    ctypes.set_last_error(0)
                    result = kernel.TerminateProcess(handle, status)
                    termination["error"] = ctypes.get_last_error()
                    return result
            try:
                with patch("highlight_process._windows_api", return_value=(ctypes, types, ExitRaceKernel())):
                    observed.cleanup()
                    self.assertTrue(observed.stopped())
                self.assertEqual(termination["error"], 5)
            finally:
                observed.close()

    def test_worker_and_descendant_are_both_observed_before_cleanup(self):
        code = ("import json,os,subprocess,sys\n"
                "child=subprocess.Popen([sys.executable,'-c',"
                "\"import time; print('ready',flush=True); time.sleep(60)\"],"
                "stdout=subprocess.PIPE,text=True)\n"
                "try:\n"
                "    assert child.stdout.readline() == 'ready\\n'\n"
                "    print(json.dumps([{'event':'start','pid':os.getpid()},"
                "{'event':'child','pid':child.pid}]),flush=True)\n"
                "    sys.stdin.read(1)\n"
                "finally:\n"
                "    if child.poll() is None: child.kill()\n"
                "    child.wait(timeout=5)\n"
                "    child.stdout.close()\n")
        parent = subprocess.Popen([sys.executable, "-c", code], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True)
        observed = {}
        try:
            records = json.loads(parent.stdout.readline())
            observed = observe_cancel_targets(records)
            self.assertEqual(len(observed), 2)
            self.assertTrue(all(not process.stopped() for process in observed.values()))
            cleanup_observed(observed)
            observed = {}
            parent.wait(timeout=5)
            for event in records:
                assert_stopped(event["pid"])
        finally:
            try:
                if parent.poll() is None:
                    # The real parent owns the child even if observation fails.
                    parent.communicate(input="\n", timeout=5)
            finally:
                if parent.poll() is None:
                    parent.kill(); parent.wait(timeout=5)
                cleanup_observed(observed)
                parent.stdin.close()
                parent.stdout.close()


if __name__ == "__main__":
    unittest.main()
