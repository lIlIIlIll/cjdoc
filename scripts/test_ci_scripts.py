#!/usr/bin/env python3
"""Contract tests for the CI routing, gate and diagnostic-bundle scripts."""

from __future__ import annotations

import json
from pathlib import Path
import signal
import subprocess
import os
import sys
import time
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ci_changes
import ci_diagnostics
import measure_paired_samples as paired
import ci_required


class ChangesRoutingTest(unittest.TestCase):
    def test_docs_only_changes_skip_native_work(self) -> None:
        planned = ci_changes.classify_paths(["docs/advanced-usage.md", "README.md"])
        self.assertTrue(planned["docs"])
        self.assertFalse(planned["native"])
        self.assertEqual({name for name, needed in planned["jobSet"].items() if needed}, set())

    def test_never_documentation_only_paths_force_native_work(self) -> None:
        for path in ("docs/schema/doc-ir.schema.json", "tools/chir-worker/src/main.cj",
                     "site/index.html", "tests/fixtures/projects/basic/cjpm.toml",
                     "src/main.cj", "cjpm.lock"):
            with self.subTest(path=path):
                planned = ci_changes.classify_paths([path])
                self.assertTrue(planned["native"], f"{path} must require native work")

    def test_an_unclassified_path_is_an_error_not_a_silent_skip(self) -> None:
        with self.assertRaises(LookupError):
            ci_changes.classify_paths(["brand-new-top-level.txt"])

    def test_unknown_dispatch_and_main_push_fall_back_to_the_full_matrix(self) -> None:
        for reason in (ci_changes.plan_for(Path("."), "a", "b", "workflow_dispatch", "refs/heads/dev"),
                       ci_changes.plan_for(Path("."), "a", "b", "push", "refs/heads/main")):
            self.assertEqual(reason["mode"], "full")
            self.assertTrue(all(reason["jobSet"].values()) is False or reason["native"])

    def test_a_push_range_is_classified_from_every_commit_in_the_range(self) -> None:
        """A push must not classify only the last commit."""
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            def git(*args: str) -> str:
                return subprocess.run(
                    ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
                     "-C", str(repo), *args],
                    capture_output=True, text=True, check=True).stdout.strip()
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            git("config", "user.email", "t@example.test")
            git("config", "user.name", "t")
            (repo / "src").mkdir()
            (repo / "docs").mkdir()
            (repo / "src/a.cj").write_text("// a\n", encoding="utf-8")
            git("add", "-A")
            git("commit", "-q", "-m", "test: add source")
            first = git("rev-parse", "HEAD")
            # Second commit touches source; third touches documentation only.
            (repo / "src/a.cj").write_text("// changed\n", encoding="utf-8")
            git("add", "-A")
            git("commit", "-q", "-m", "test: change source")
            (repo / "docs/x.md").write_text("docs\n", encoding="utf-8")
            git("add", "-A")
            git("commit", "-q", "-m", "docs: docs only")
            head = git("rev-parse", "HEAD")

            # Classifying only the final commit would skip native work.
            self.assertEqual(ci_changes.plan_for(repo, head, head, "pull_request", "refs/heads/dev")["mode"], "full")
            whole = ci_changes.plan_for(repo, first, head, "push", "refs/heads/dev")
            self.assertTrue(whole["native"], "the range includes a source change")


class RequiredGateTest(unittest.TestCase):
    def evaluate(self, outcomes: dict, plan: str) -> int:
        planned, routable, _ = ci_required.planned_set(plan)
        problems = ci_required.evaluate(outcomes, planned, routable)
        return 1 if problems else 0

    def test_every_planned_job_must_succeed(self) -> None:
        ok = {"changes": {"result": "success"}, "candidate-linux": {"result": "success"},
              "linux-acceptance": {"result": "success"}, "candidate-other": {"result": "success"}}
        self.assertEqual(self.evaluate(ok, ""), 0)
        for mutation in ({"candidate-linux": {"result": "failure"}},
                         {"linux-acceptance": {"result": "skipped"}},
                         {"candidate-other": {"result": "cancelled"}}):
            with self.subTest(mutation=mutation):
                broken = {**ok, **mutation}
                self.assertEqual(self.evaluate(broken, ""), 1)

    def test_a_planned_job_missing_from_the_graph_fails(self) -> None:
        incomplete = {"changes": {"result": "success"}}
        self.assertEqual(self.evaluate(incomplete, ""), 1)

    def test_unplanned_jobs_may_skip_but_not_fail(self) -> None:
        light_plan = json.dumps({"mode": "classified",
                                 "jobSet": {"candidate-linux": False,
                                            "linux-acceptance": False,
                                            "candidate-other": False}})
        skipped = {"changes": {"result": "success"}, "candidate-linux": {"result": "skipped"},
                   "linux-acceptance": {"result": "skipped"}, "candidate-other": {"result": "skipped"}}
        self.assertEqual(self.evaluate(skipped, light_plan), 0)
        broken = {**skipped, "candidate-other": {"result": "failure"}}
        self.assertEqual(self.evaluate(broken, light_plan), 1)

    def test_the_classifier_cannot_be_skipped(self) -> None:
        light_plan = json.dumps({"mode": "classified",
                                 "jobSet": {"candidate-linux": False,
                                            "linux-acceptance": False,
                                            "candidate-other": False}})
        without_changes = {"candidate-linux": {"result": "skipped"},
                           "linux-acceptance": {"result": "skipped"},
                           "candidate-other": {"result": "skipped"}}
        self.assertEqual(self.evaluate(without_changes, light_plan), 1)

    def test_a_plan_that_does_not_cover_the_routable_jobs_is_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            ci_required.planned_set(json.dumps({"mode": "classified", "jobSet": {}}))


class DiagnosticsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        (self.repo / "tests/fixtures/golden-v15").mkdir(parents=True)
        (self.repo / "tests/fixtures/golden-v15/basic.docs.json").write_text("{}\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)

    def test_a_bundle_is_never_marked_as_an_accepted_baseline(self) -> None:
        target = self.repo / "target/acceptance/basic"
        (target / "first").mkdir(parents=True)
        (target / "first/docs.json").write_text('{"a":1}\n', encoding="utf-8")
        out = self.root / "out"
        document = ci_diagnostics.collect(self.repo, [self.repo / "target/acceptance"], out)
        self.assertFalse(document["acceptedBaseline"])
        self.assertEqual(document["kind"], "failure")
        self.assertTrue(document["available"])
        self.assertTrue((out / "diagnostics.json").is_file())
        self.assertTrue(any(entry["label"].endswith("actual-first") for entry in document["files"]))

    def test_a_stage_evidence_root_includes_the_process_snapshot(self) -> None:
        """The wedge post-mortem lives in evidence, next to the stage records."""
        evidence = self.repo / "target/ci-evidence"
        evidence.mkdir(parents=True)
        (evidence / "stages.json").write_text("{}\n", encoding="utf-8")
        (evidence / "native-process-snapshot.txt").write_text(
            "sampledAt: x\n123 futex_do_wait\n", encoding="utf-8")
        out = self.root / "evidence-out"
        document = ci_diagnostics.collect(self.repo, [evidence], out)
        collected = {Path(entry["path"]).name for entry in document["files"]}
        self.assertIn("native-process-snapshot.txt", collected)
        self.assertIn("stages.json", collected)

    def test_a_missing_target_still_writes_a_bundle(self) -> None:
        out = self.root / "absent-out"
        document = ci_diagnostics.collect(self.repo, [self.root / "does-not-exist"], out)
        self.assertFalse(document["available"])
        # The upload step's `if-no-files-found: error` is what proves this ran.
        self.assertTrue((out / "diagnostics.json").is_file())

    def test_external_stage_roots_keep_distinct_paths(self) -> None:
        """Same-named files from a stage-private root must not collide."""
        external = self.root / "stage-cli"
        for fixture in ("basic", "types"):
            (external / fixture / "first").mkdir(parents=True)
            (external / fixture / "first/docs.json").write_text(f'{{"{fixture}":1}}\n', encoding="utf-8")
        out = self.root / "external-out"
        document = ci_diagnostics.collect(self.repo, [external], out)
        paths = [entry["path"] for entry in document["files"]]
        self.assertEqual(len(paths), len(set(paths)), f"colliding diagnostic paths: {paths}")
        external_paths = sorted(path for path in paths if path.endswith("first/docs.json"))
        self.assertEqual(len(external_paths), 2,
                         f"the two fixture results must not collapse: {external_paths}")
        self.assertNotEqual(external_paths[0], external_paths[1])
        # Each record's digest must match the file actually on disk.
        for entry in document["files"]:
            self.assertEqual(ci_diagnostics.sha256_file(out / entry["path"]), entry["sha256"])

    def test_byte_and_file_budgets_are_reported_not_hidden(self) -> None:
        target = self.repo / "target/acceptance/basic"
        (target / "first").mkdir(parents=True)
        (target / "first/docs.json").write_text('{"a":1}\n', encoding="utf-8")
        out = self.root / "limited-out"
        document = ci_diagnostics.collect(self.repo, [self.repo / "target/acceptance"], out,
                                          max_bytes=1, max_files=1)
        self.assertTrue(document["omitted"])
        self.assertTrue(all("budget" in entry["reason"] for entry in document["omitted"]))



class RunWithTimeoutTests(unittest.TestCase):
    """The portable bound: pass through, expire at 124, and kill the group."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.script = Path(__file__).resolve().parent / "run_with_timeout.py"

    def run_wrapper(self, timeout: str, *command: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(self.script), timeout, "--", *command],
            capture_output=True, text=True, env=self.short_grace())

    def short_grace(self) -> dict:
        """`GRACE_SECONDS` is production-scale; tests must not wait it out."""
        environment = dict(os.environ)
        environment["CJDOC_TIMEOUT_GRACE_SECONDS"] = "5"
        return environment

    def test_a_fast_command_passes_through_with_its_own_status(self) -> None:
        done = self.run_wrapper("30", sys.executable, "-c", "import sys; sys.exit(3)")
        self.assertEqual(done.returncode, 3)

    def test_an_expired_command_reports_124_like_timeout_does(self) -> None:
        done = self.run_wrapper("1", sys.executable, "-c", "import time; time.sleep(60)")
        self.assertEqual(done.returncode, 124, done.stderr)
        self.assertIn("exceeded 1s", done.stderr)

    @unittest.skipUnless(os.name == "posix", "POSIX process groups only")
    def test_expiry_kills_a_child_that_stays_in_the_group(self) -> None:
        marker = f"cjdoc-timeout-wrapper-{os.getpid()}"
        done = self.run_wrapper(
            "1", "/bin/bash", "-c", f'sh -c "exec -a {marker} sleep 60" & sleep 60')
        self.assertEqual(done.returncode, 124)
        deadline = time.monotonic() + 5
        survivors = "1"
        while time.monotonic() < deadline:
            probe = subprocess.run(["pgrep", "-f", marker], capture_output=True, text=True)
            survivors = probe.stdout.strip()
            if not survivors:
                break
            time.sleep(0.1)
        self.assertEqual(survivors, "", "the group outlived the deadline")

    @unittest.skipUnless(os.name == "posix", "POSIX process groups only")
    def test_expiry_signals_the_group_with_term_first(self) -> None:
        """The command must get a chance to report and clean up before any KILL."""
        marker = Path(self.temporary.name) / "trapped"
        script = (
            "import signal, sys, time\n"
            "def handler(signum, frame):\n"
            f"    open({str(marker)!r}, 'w').write('term')\n"
            "    sys.exit(5)\n"
            "signal.signal(signal.SIGTERM, handler)\n"
            "time.sleep(60)\n")
        done = self.run_wrapper("1", sys.executable, "-c", script)
        self.assertEqual(done.returncode, 124)
        self.assertTrue(marker.exists(),
                        "the command never received SIGTERM before being killed")

    @unittest.skipUnless(os.name == "posix", "POSIX process groups only")
    def test_the_grace_covers_a_worker_after_its_leader_exits(self) -> None:
        """A worker's own TERM handler must get the grace, not be killed at once."""
        finished = Path(self.temporary.name) / "worker-finished"
        marker = f"cjdoc-timeout-grace-{os.getpid()}"
        worker = (
            "import signal, sys, time\n"
            "def handler(signum, frame):\n"
            "    time.sleep(1)\n"
            f"    open({str(finished)!r}, 'w').write('ok')\n"
            "    sys.exit(0)\n"
            "signal.signal(signal.SIGTERM, handler)\n"
            "time.sleep(60)\n")
        leader = (
            "import subprocess, sys, time\n"
            f"subprocess.Popen([sys.executable, '-c', {worker!r}])\n"
            "time.sleep(60)\n")
        # The leader obeys TERM and exits at once; only the grace can let the worker
        # finish its handler.
        done = subprocess.run(
            [sys.executable, str(self.script), "1", "--",
             sys.executable, "-c", leader],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=self.short_grace())
        self.assertEqual(done.returncode, 124)
        self.assertTrue(finished.exists(),
                        "the worker was killed before its TERM handler completed")

    @unittest.skipUnless(os.name == "posix", "POSIX process groups only")
    def test_a_worker_that_ignores_term_dies_with_its_leader(self) -> None:
        """The leader obeying TERM must not let a stubborn worker survive."""
        marker = f"cjdoc-timeout-stubborn-{os.getpid()}"
        # The leader runs to the deadline and obeys TERM; the worker ignores it and
        # would keep the shared outputs open on its own.
        script = Path(self.temporary.name) / "leader.sh"
        script.write_text(
            "sh -c 'trap \"\" TERM; exec -a "
            f"{marker} sleep 60' &\n"
            "sleep 60\n", encoding="utf-8")
        # Output must NOT be captured: the stubborn worker inherits the pipe, so
        # capturing would block until the worker exits on its own and the assertion
        # below could never see it alive.
        done = subprocess.run(
            [sys.executable, str(self.script), "1", "--", "/bin/bash", str(script)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=self.short_grace())
        self.assertEqual(done.returncode, 124)
        deadline = time.monotonic() + 5
        survivors = "1"
        while time.monotonic() < deadline:
            survivors = subprocess.run(["pgrep", "-f", marker], capture_output=True,
                                       text=True).stdout.strip()
            if not survivors:
                break
            time.sleep(0.1)
        self.assertEqual(survivors, "", "a worker outlived the deadline and its leader")

    @unittest.skipUnless(os.name == "posix", "POSIX process groups only")
    def test_a_hangup_kills_the_child_group(self) -> None:
        """A run that loses its terminal must not leave the command behind."""
        marker = f"cjdoc-timeout-hup-{os.getpid()}"
        wrapper = subprocess.Popen(
            [sys.executable, str(self.script), "60", "--",
             "/bin/bash", "-c", f'sh -c "exec -a {marker} sleep 60" & sleep 60'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=self.short_grace())
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if subprocess.run(["pgrep", "-f", marker], capture_output=True,
                                  text=True).stdout.strip():
                    break
                time.sleep(0.05)
            self.assertTrue(
                subprocess.run(["pgrep", "-f", marker], capture_output=True,
                               text=True).stdout.strip(),
                "the child never started")
            wrapper.send_signal(signal.SIGHUP)
            wrapper.wait(timeout=30)
            deadline = time.monotonic() + 5
            survivors = "1"
            while time.monotonic() < deadline:
                survivors = subprocess.run(["pgrep", "-f", marker], capture_output=True,
                                           text=True).stdout.strip()
                if not survivors:
                    break
                time.sleep(0.1)
            self.assertEqual(survivors, "", "the child group survived SIGHUP")
        finally:
            if wrapper.poll() is None:
                wrapper.kill()
                wrapper.wait(timeout=10)
            subprocess.run(["pkill", "-f", marker], check=False)

    @unittest.skipUnless(os.name == "posix", "POSIX process groups only")
    def test_interrupting_the_wrapper_kills_the_child_group(self) -> None:
        """SIGTERM to the wrapper must not leave the command running."""
        marker = f"cjdoc-timeout-interrupt-{os.getpid()}"
        wrapper = subprocess.Popen(
            [sys.executable, str(self.script), "60", "--",
             "/bin/bash", "-c", f'sh -c "exec -a {marker} sleep 60" & sleep 60'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=self.short_grace())
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if subprocess.run(["pgrep", "-f", marker], capture_output=True,
                                  text=True).stdout.strip():
                    break
                time.sleep(0.05)
            self.assertTrue(
                subprocess.run(["pgrep", "-f", marker], capture_output=True,
                               text=True).stdout.strip(),
                "the child never started")
            wrapper.send_signal(signal.SIGTERM)
            wrapper.wait(timeout=30)
            deadline = time.monotonic() + 5
            survivors = "1"
            while time.monotonic() < deadline:
                survivors = subprocess.run(["pgrep", "-f", marker], capture_output=True,
                                           text=True).stdout.strip()
                if not survivors:
                    break
                time.sleep(0.1)
            self.assertEqual(survivors, "", "the child group survived the wrapper")
        finally:
            if wrapper.poll() is None:
                wrapper.kill()
                wrapper.wait(timeout=10)
            subprocess.run(["pkill", "-f", marker], check=False)

    @unittest.skipUnless(os.name == "posix", "POSIX process groups only")
    def test_interrupt_during_launch_kills_the_child_group(self) -> None:
        """Cancellation while Popen returns still cleans up the launched command."""
        directory = Path(self.temporary.name)
        spawned = directory / "spawned"
        child_ready = directory / "child-ready"
        interrupted = directory / "interrupted"
        release = directory / "release"
        terminated = directory / "terminated"
        # Run the real public CLI, pausing only Popen's return. A tracked handler
        # acknowledges signal delivery before the test lets launch finish, so this
        # exercises the startup window without a scheduler-dependent sleep.
        (directory / "sitecustomize.py").write_text(
            "import os, signal, subprocess, sys, time\n"
            "from pathlib import Path\n"
            "if os.path.abspath(sys.argv[0]) == os.environ.get('CJDOC_TEST_WRAPPER'):\n"
            "    directory = Path(os.environ['CJDOC_TEST_LAUNCH_DIRECTORY'])\n"
            "    real_popen = subprocess.Popen\n"
            "    real_signal = signal.signal\n"
            "    def tracked_signal(number, handler):\n"
            "        if callable(handler):\n"
            "            def tracked(number, frame):\n"
            "                (directory / 'interrupted').write_text(str(number))\n"
            "                return handler(number, frame)\n"
            "            return real_signal(number, tracked)\n"
            "        return real_signal(number, handler)\n"
            "    def paused_popen(*args, **kwargs):\n"
            "        process = real_popen(*args, **kwargs)\n"
            "        (directory / 'spawned').write_text(str(process.pid))\n"
            "        deadline = time.monotonic() + 10\n"
            "        while not (directory / 'release').exists():\n"
            "            if time.monotonic() >= deadline:\n"
            "                raise RuntimeError('launch was never released')\n"
            "            time.sleep(0.01)\n"
            "        return process\n"
            "    signal.signal = tracked_signal\n"
            "    subprocess.Popen = paused_popen\n",
            encoding="utf-8")
        child = (
            "import os, signal, sys, time\n"
            "from pathlib import Path\n"
            "def terminate(number, frame):\n"
            f"    Path({str(terminated)!r}).write_text('term')\n"
            "    sys.exit(0)\n"
            "signal.signal(signal.SIGTERM, terminate)\n"
            f"Path({str(child_ready)!r}).write_text(str(os.getpid()))\n"
            "time.sleep(60)\n")
        environment = self.short_grace()
        environment.update(PYTHONPATH=str(directory), CJDOC_TEST_WRAPPER=str(self.script),
                           CJDOC_TEST_LAUNCH_DIRECTORY=str(directory))
        wrapper = subprocess.Popen(
            [sys.executable, str(self.script), "60", "--", sys.executable, "-c", child],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=environment)
        child_pid = None
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and not (spawned.exists() and child_ready.exists()):
                self.assertIsNone(wrapper.poll(), "wrapper exited before launching the child")
                time.sleep(0.01)
            if spawned.exists():
                child_pid = int(spawned.read_text())
            self.assertTrue(spawned.exists() and child_ready.exists(), "child never became ready")
            wrapper.send_signal(signal.SIGTERM)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and not interrupted.exists() and wrapper.poll() is None:
                time.sleep(0.01)
            # The old implementation exits here without an installed handler. The
            # fixed one records the signal and must defer cleanup until binding.
            self.assertTrue(interrupted.exists(), "SIGTERM escaped startup cleanup")
            self.assertIsNone(wrapper.poll(), "startup cancellation was not deferred")
            release.write_text("continue", encoding="utf-8")
            wrapper.wait(timeout=30)
            self.assertEqual(wrapper.returncode, -signal.SIGTERM)
            self.assertTrue(terminated.exists(), "the launched child never received SIGTERM")
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)
        finally:
            release.touch()
            if wrapper.poll() is None:
                wrapper.kill()
                wrapper.wait(timeout=10)
            if child_pid is not None:
                try:
                    os.killpg(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


    @unittest.skipUnless(os.name == "posix", "POSIX signals only")
    def test_launch_failure_preserves_errors_and_pending_cancellation(self) -> None:
        directory = Path(self.temporary.name)
        for interrupted in (False, True):
            with self.subTest(interrupted=interrupted):
                (directory / "sitecustomize.py").write_text(
                    "import os, signal, subprocess\n"
                    "def fail(*args, **kwargs):\n"
                    + ("    os.kill(os.getpid(), signal.SIGTERM)\n" if interrupted else "")
                    + "    raise OSError('launch failed')\n"
                    "subprocess.Popen = fail\n", encoding="utf-8")
                done = subprocess.run(
                    [sys.executable, str(self.script), "60", "--", "unused-command"],
                    env=dict(self.short_grace(), PYTHONPATH=str(directory)),
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(done.returncode, -signal.SIGTERM if interrupted else 1)
                if not interrupted:
                    self.assertIn("OSError: launch failed", done.stderr)




class PairedSampleTests(unittest.TestCase):
    """DONE-03's classification: never assume a condition the evidence omits."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write_artifact(self, name: str, cache: dict | None) -> None:
        directory = self.root / name
        directory.mkdir(parents=True)
        document = {"schemaVersion": "cjdoc.ci-stage/1", "stages": [
            {"stageId": "native", "kind": "native", "wallMs": 1.0,
             "environment": ({} if cache is None else {"cache": cache})}]}
        (directory / "stages.json").write_text(json.dumps(document), encoding="utf-8")

    def test_the_cache_state_comes_from_the_job_artifact(self) -> None:
        self.write_artifact("ci-timing-ci-linux-x64-1-1", {"cjv": "hit"})
        self.write_artifact("ci-timing-ci-windows-x64-1-1", {"cjv": "miss"})
        states = paired.job_cache_states(self.root)
        self.assertEqual(states["ci-timing-ci-linux-x64-1-1"], "hit")
        self.assertEqual(states["ci-timing-ci-windows-x64-1-1"], "miss")

    def test_a_job_name_matches_its_own_artifact_toolchain_words_included(self) -> None:
        states = {"ci-timing-ci-linux-x64-1-1": "hit",
                  "ci-timing-ci-windows-x64-1-1": "miss"}
        # The job name carries `Cangjie`/`STS`/`stdx`, which the artifact name does not.
        self.assertEqual(paired._job_state_for("linux-x64 / Cangjie 1.2.0 STS + stdx", states),
                         "hit")
        self.assertEqual(paired._job_state_for("windows-x64 / Cangjie 1.2.0 STS + stdx", states),
                         "miss")

    def test_an_unrecorded_state_is_unknown_not_assumed(self) -> None:
        """The pre-existing history has no cache field; it must not become a cell."""
        self.write_artifact("ci-timing-ci-linux-x64-1-1", None)
        states = paired.job_cache_states(self.root)
        self.assertEqual(states["ci-timing-ci-linux-x64-1-1"], "unknown")
        self.assertEqual(paired._job_state_for("linux-x64 / Cangjie 1.2.0 STS + stdx", states),
                         "unknown")

    def test_a_run_mixing_states_is_recorded_per_job(self) -> None:
        """One run legitimately has both conditions; a run-level answer would hide it."""
        self.write_artifact("ci-timing-ci-linux-x64-1-1", {"cjv": "hit"})
        self.write_artifact("ci-timing-ci-macos-arm64-1-1", {"cjv": "miss"})
        states = paired.job_cache_states(self.root)
        self.assertEqual(sorted(states.values()), ["hit", "miss"])

    def test_a_stage_that_disagrees_with_itself_is_not_a_cell(self) -> None:
        directory = self.root / "ci-timing-ci-linux-x64-1-1"
        directory.mkdir(parents=True)
        (directory / "stages.json").write_text(json.dumps({"stages": [
            {"environment": {"cache": {"cjv": "hit"}}},
            {"environment": {"cache": {"cjv": "miss"}}}]}), encoding="utf-8")
        self.assertEqual(paired.job_cache_states(self.root)["ci-timing-ci-linux-x64-1-1"],
                         "mixed")

    def test_cells_are_keyed_by_job_shape_not_only_cache_state(self) -> None:
        """A Linux hit must never be pooled with a macOS miss."""
        samples = [
            {"run": 1, "attempt": 1, "revision": "a" * 8, "event": "push", "job": "linux-x64 / Cangjie",
             "shape": "linux-x64", "conclusion": "success", "state": "hit", "jobMinutes": 20.0,
             "runWallMinutes": 25.0, "runRunnerMinutes": 50.0},
            {"run": 2, "attempt": 1, "revision": "b" * 8, "event": "push", "job": "macos-arm64 / Cangjie",
             "shape": "macos-arm64", "conclusion": "success", "state": "miss", "jobMinutes": 10.0,
             "hasEvidence": True,
             "runWallMinutes": 25.0, "runRunnerMinutes": 50.0},
        ]
        out = self.root / "cells.md"
        result = paired.report(samples, "ci.yml", out)
        self.assertEqual(sorted(k.split("|")[0] for k in result["cells"]),
                         ["linux-x64/hit", "macos-arm64/miss"])
        text = out.read_text(encoding="utf-8")
        self.assertIn("linux-x64 / **hit**", text)
        self.assertIn("macos-arm64 / **miss**", text)

    def test_failed_jobs_are_listed_and_excluded_from_cells(self) -> None:
        samples = [
            {"run": 1, "attempt": 2, "revision": "c" * 8, "event": "push", "job": "linux-x64 / Cangjie",
             "shape": "linux-x64", "conclusion": "failure", "state": "n/a", "jobMinutes": 5.0,
             "runWallMinutes": 25.0, "runRunnerMinutes": 50.0},
        ]
        out = self.root / "failed.md"
        result = paired.report(samples, "ci.yml", out)
        self.assertEqual(result["cells"], {})
        self.assertEqual(result["failures"], 1)
        text = out.read_text(encoding="utf-8")
        self.assertIn("**failure**", text)
        self.assertIn("Re-run attempts present in this sample: 2", text)

    def test_a_job_shape_is_stable_across_toolchain_pins(self) -> None:
        self.assertEqual(paired.job_shape("linux-x64 / Cangjie 1.2.0 STS + stdx"), "linux-x64")
        self.assertEqual(paired.job_shape("linux-x64 / Cangjie 2.0.0 STS + stdx"), "linux-x64")

    def test_the_two_linux_artifacts_are_never_confused(self) -> None:
        """The candidate and the acceptance job must not share a state by tie-break."""
        states = {"ci-timing-build-linux-candidate-1-1": "hit",
                  "ci-timing-ci-linux-x64-1-1": "miss"}
        self.assertEqual(paired._job_state_for(
            "Linux candidate / Linux candidate / Cangjie 1.2.0 STS + stdx", states), "hit")
        self.assertEqual(paired._job_state_for(
            "linux-x64 / Cangjie 1.2.0 STS + stdx", states), "miss")

    def test_a_job_without_a_timing_artifact_is_never_a_requirement(self) -> None:
        """`CI required` can never be hit or miss, so it must not appear as a cell."""
        samples = [
            {"run": 1, "attempt": 1, "revision": "d" * 8, "event": "push", "job": "CI required",
             "shape": "ci required", "conclusion": "success", "state": "unknown", "jobMinutes": 0.1,
             "runWallMinutes": 25.0, "runRunnerMinutes": 50.0},
            {"run": 1, "attempt": 1, "revision": "d" * 8, "event": "push",
             "job": "linux-x64 / Cangjie", "shape": "linux-x64", "conclusion": "success",
             "state": "hit", "jobMinutes": 20.0,
             "runWallMinutes": 25.0, "runRunnerMinutes": 50.0},
        ]
        out = self.root / "req.md"
        result = paired.report(samples, "ci.yml", out)
        self.assertEqual(sorted(k.split("|")[0] for k in result["cells"]), ["linux-x64/hit"])
        text = out.read_text(encoding="utf-8")
        self.assertNotIn("**ci required**", text)
        self.assertNotIn("ci required / **hit**", text)

    def test_attempts_are_enumerated_not_resolved_to_the_latest(self) -> None:
        calls = []

        def fake_samples(repository, run, run_id, attempt, cache_root, earlier, failures,
                         workflow):
            calls.append(attempt)
            return [], set()

        original_samples = paired._attempt_samples
        original_runs = paired.workflow_runs
        paired._attempt_samples = fake_samples
        paired.workflow_runs = lambda *a, **k: [
            {"id": 7, "run_attempt": 3, "head_sha": "e" * 40, "event": "push",
             "status": "completed", "conclusion": "success"}]
        try:
            paired.collect("o/r", "CI", 1, self.root)
        finally:
            paired._attempt_samples = original_samples
            paired.workflow_runs = original_runs
        self.assertEqual(calls, [1, 2, 3])

    def test_a_cache_bearing_shape_stays_a_requirement_when_unknown(self) -> None:
        """A platform whose artifacts expired must still show as an unmet cell."""
        samples = [
            {"run": 1, "attempt": 1, "revision": "f" * 8, "event": "push",
             "job": "macos-arm64 / Cangjie", "shape": "macos-arm64", "conclusion": "success",
             "state": "unknown", "jobMinutes": 17.0, "hasEvidence": True,
             "runWallMinutes": 25.0, "runRunnerMinutes": 50.0},
        ]
        out = self.root / "expired.md"
        paired.report(samples, "ci.yml", out)
        text = out.read_text(encoding="utf-8")
        self.assertIn("macos-arm64 / **miss**", text)
        self.assertIn("macos-arm64 / **hit**", text)

    def test_an_orchestration_job_is_not_a_cache_requirement(self) -> None:
        self.assertIsNone(paired.job_artifact_stem("CI required"))
        self.assertIsNone(paired.job_artifact_stem("Classify changes"))
        self.assertEqual(paired.job_artifact_stem("linux-x64 / Cangjie"), "ci-linux-x64")

    def test_a_failed_only_shape_is_still_a_requirement(self) -> None:
        """A platform that only ever failed must report zero successful samples."""
        samples = [
            {"run": 1, "attempt": 1, "revision": "9" * 8, "event": "push",
             "job": "windows-x64 / Cangjie", "shape": "windows-x64", "conclusion": "failure",
             "state": "n/a", "jobMinutes": 5.0, "hasEvidence": True,
             "runWallMinutes": 25.0, "runRunnerMinutes": 50.0},
            {"run": 2, "attempt": 1, "revision": "8" * 8, "event": "push",
             "job": "linux-x64 / Cangjie", "shape": "linux-x64", "conclusion": "success",
             "state": "hit", "jobMinutes": 20.0, "hasEvidence": True,
             "runWallMinutes": 25.0, "runRunnerMinutes": 50.0},
        ]
        out = self.root / "failed-shape.md"
        paired.report(samples, "ci.yml", out)
        text = out.read_text(encoding="utf-8")
        self.assertIn("windows-x64 / **hit**", text)
        self.assertIn("windows-x64 / **miss**", text)

    def test_a_carried_forward_job_is_not_counted_twice(self) -> None:
        """A re-run's attempt 2 must not re-charge a job attempt 1 already ran."""
        calls = {}

        def fake_attempt(repository, run, run_id, attempt, cache_root, earlier, failures,
                         workflow):
            # Attempt 2 returns the same job name and started_at as attempt 1.
            job = {"name": "macos-arm64 / Cangjie", "started_at": "2026-01-01T00:00:00Z",
                   "conclusion": "success", "id": 1}
            kept = [(job, "e")] if (job["name"], job["started_at"]) not in earlier else []
            calls[attempt] = len(kept)
            return ([{"run": run_id, "attempt": attempt, "revision": "a" * 8, "event": "push",
                       "job": job["name"][:34], "shape": "macos-arm64", "conclusion": "success",
                       "state": "hit", "jobMinutes": 1.0,
                       "runWallMinutes": 1.0, "runRunnerMinutes": 1.0} for _ in range(len(kept))],
                    {(job["name"], job["started_at"])})

        original = paired._attempt_samples
        original_runs = paired.workflow_runs
        paired._attempt_samples = fake_attempt
        paired.workflow_runs = lambda *a, **k: [
            {"id": 5, "run_attempt": 2, "head_sha": "b" * 40, "event": "push",
             "status": "completed", "conclusion": "success"}]
        try:
            paired.collect("o/r", "CI", 1, self.root)
        finally:
            paired._attempt_samples = original
            paired.workflow_runs = original_runs
        self.assertEqual(calls, {1: 1, 2: 0}, "the carried-forward job must be dropped")

    def test_the_same_shape_under_two_conditions_is_two_cells(self) -> None:
        """A hit and a miss are distinct cells; the revision is not part of the key."""
        def sample(rev, state, minutes):
            return {"run": 1, "attempt": 1, "revision": rev, "event": "push",
                    "job": "linux-x64 / Cangjie", "shape": "linux-x64",
                    "conclusion": "success", "state": state, "jobMinutes": minutes, "hasEvidence": True,
                    "condition": "ubuntu|1.2.0|d|x86_64|--jobs 1,-O1",
                    "runWallMinutes": 25.0, "runRunnerMinutes": 50.0}

        samples = [sample("a" * 40, "miss", 20.0), sample("b" * 40, "hit", 10.0)]
        out = self.root / "conditions.md"
        result = paired.report(samples, "ci.yml", out)
        self.assertEqual(len(result["cells"]), 2, result["cells"])
        text = out.read_text(encoding="utf-8")
        # The environment is the pairing unit, and revisions are still visible.
        self.assertIn("ubuntu|1.2.0|d|x86_64", text)

    def test_two_revisions_under_one_environment_share_a_cell(self) -> None:
        """DONE-03's before/after samples are different commits by definition.

        Keying on the revision made every push its own cell with a single sample, so
        five per cell was unreachable. Samples of the same shape, state and
        environment must pool across revisions, and the cell must name those
        revisions so the pooling is not silent.
        """
        def sample(rev, state, minutes):
            return {"run": 1, "attempt": 1, "revision": rev, "event": "push",
                    "job": "linux-x64 / Cangjie", "shape": "linux-x64",
                    "conclusion": "success", "state": state, "jobMinutes": minutes,
                    "hasEvidence": True,
                    "condition": "ubuntu|1.2.0|d|x86_64|--jobs 1,-O1",
                    "runWallMinutes": 25.0, "runRunnerMinutes": 50.0}

        samples = [sample(f"{n:040x}", "hit", 10.0) for n in range(1, 6)]
        out = self.root / "pooled.md"
        result = paired.report(samples, "ci.yml", out)
        key = "linux-x64/hit|ubuntu|1.2.0|d|x86_64|--jobs 1,-O1"
        self.assertEqual(result["cells"].get(key), 5, result["cells"])
        text = out.read_text(encoding="utf-8")
        self.assertIn("revisions=", text)

    def test_five_hits_and_five_misses_under_different_conditions_is_not_met(self) -> None:
        """The paired comparison needs BOTH conditions under the SAME condition."""
        def sample(env, state):
            return {"run": 1, "attempt": 1, "revision": "a" * 40, "event": "push",
                    "job": "linux-x64 / Cangjie", "shape": "linux-x64",
                    "conclusion": "success", "state": state, "jobMinutes": 10.0,
                    "condition": env, "runWallMinutes": 25.0, "runRunnerMinutes": 50.0}
        # Five hits and five misses, but under DIFFERENT environments: each state is
        # satisfied alone while no single matched environment has both.
        samples = [sample("ubuntu|1.2.0|d|x86_64|--jobs 1,-O1", "hit") for _ in range(5)]
        samples += [sample("macos|1.2.0|e|aarch64|--jobs 1,-O1", "miss") for _ in range(5)]
        out = self.root / "crossed.md"
        result = paired.report(samples, "ci.yml", out)
        text = out.read_text(encoding="utf-8")
        self.assertFalse(any(count >= 5 for count in result["pairedPerCondition"].values()),
                         result["pairedPerCondition"])
        self.assertIn("paired samples under this condition: 0 — NOT met", text)

    def test_the_pairing_signature_excludes_the_revision(self) -> None:
        """`job_conditions` must key on the environment only.

        Two artifacts recorded from the SAME environment but DIFFERENT commits have to
        produce the same signature, or DONE-03's before/after pairing is impossible.
        """
        root = self.root / "conditions-evidence"
        for name, commit in (("a", "a" * 40), ("b", "b" * 40)):
            directory = root / name
            directory.mkdir(parents=True)
            (directory / "stages.json").write_text(json.dumps({"stages": [{
                "environment": {"checkoutCommit": commit, "runnerImage": "ubuntu22",
                                "sdkVersion": "1.2.0", "stdxDigest": "d",
                                "toolchainTarget": "x86_64", "compileOptions": ["--jobs 1", "-O1"]}
            }]}), encoding="utf-8")
        conditions = paired.job_conditions(root)
        self.assertEqual(len(conditions), 2)
        signatures = set(conditions.values())
        self.assertEqual(len(signatures), 1, signatures)
        self.assertNotIn("a" * 40, signatures.pop())

    def test_a_later_stage_with_different_flags_is_not_pooled(self) -> None:
        """The signature must cover EVERY stage, not only the first."""
        root = self.root / "stage-flags"
        for name, flags in (("a", ["--jobs 1", "-O1"]), ("b", ["--jobs 1", "-O2"])):
            directory = root / name
            directory.mkdir(parents=True)
            common = {"runnerImage": "ubuntu22", "sdkVersion": "1.2.0",
                      "stdxDigest": "d", "toolchainTarget": "x86_64"}
            (directory / "stages.json").write_text(json.dumps({"stages": [
                {"environment": {**common, "compileOptions": ["--jobs 1", "-O1"]}},
                {"environment": {**common, "compileOptions": flags}},
            ]}), encoding="utf-8")
        conditions = paired.job_conditions(root)
        self.assertEqual(len(set(conditions.values())), 2, conditions)

    def test_failed_only_environments_stay_requirements(self) -> None:
        """An environment seen only in failed samples must still be listed."""
        def sample(env, state, conclusion):
            return {"run": 1, "attempt": 1, "revision": "a" * 40, "event": "push",
                    "job": "linux-x64 / Cangjie", "shape": "linux-x64",
                    "conclusion": conclusion, "state": state, "jobMinutes": 10.0,
                    "hasEvidence": True, "condition": env,
                    "runWallMinutes": 25.0, "runRunnerMinutes": 50.0}
        samples = [sample("env-A", "hit", "success"),
                   sample("env-B", "miss", "failure")]
        out = self.root / "failed-env.md"
        paired.report(samples, "ci.yml", out)
        text = out.read_text(encoding="utf-8")
        self.assertIn("env-B", text)
        self.assertIn("env-B`: 0 collected", text)

    def test_the_run_table_carries_the_environment_and_revision(self) -> None:
        """Attribution must be auditable from the report itself."""
        def sample(env, revision):
            return {"run": 1, "attempt": 1, "revision": revision, "event": "push",
                    "job": "linux-x64 / Cangjie", "shape": "linux-x64",
                    "conclusion": "success", "state": "hit", "jobMinutes": 10.0,
                    "hasEvidence": True, "condition": env,
                    "runWallMinutes": 25.0, "runRunnerMinutes": 50.0}
        samples = [sample("env-X", "a" * 8), sample("env-Y", "b" * 8)]
        out = self.root / "attribution.md"
        paired.report(samples, "ci.yml", out)
        text = out.read_text(encoding="utf-8")
        self.assertIn("| environment |", text)
        # The environment must appear on the ROW, next to its revision, so a cell that
        # pools several revisions can still be attributed.
        rows = [line for line in text.splitlines()
                if line.startswith("| 1 |") and "linux-x64" in line]
        self.assertEqual(len(rows), 2, rows)
        self.assertTrue(any("env-X" in row and "a" * 8 in row for row in rows), rows)
        self.assertTrue(any("env-Y" in row and "b" * 8 in row for row in rows), rows)

    def test_a_browser_identity_difference_splits_cells(self) -> None:
        """If a producer records browser/font identity, it must split cells."""
        root = self.root / "browser"
        for name, version in (("a", "chromium-1"), ("b", "chromium-2")):
            directory = root / name
            directory.mkdir(parents=True)
            (directory / "stages.json").write_text(json.dumps({"stages": [{
                "environment": {"runnerImage": "ubuntu22", "sdkVersion": "1.2.0",
                                "stdxDigest": "d", "toolchainTarget": "x86_64",
                                "compileOptions": ["--jobs 1", "-O1"],
                                "browserIdentity": version}}]}), encoding="utf-8")
        conditions = paired.job_conditions(root)
        self.assertEqual(len(set(conditions.values())), 2, conditions)

    def test_the_toolchain_fingerprint_splits_cells(self) -> None:
        """Same sdkVersion but a different installation must not share a cell."""
        root = self.root / "fingerprint"
        for name, fingerprint in (("a", "fp-1"), ("b", "fp-2")):
            directory = root / name
            directory.mkdir(parents=True)
            (directory / "stages.json").write_text(json.dumps({"stages": [{
                "environment": {"runnerImage": "ubuntu22", "sdkVersion": "1.2.0",
                                "stdxDigest": "d", "toolchainTarget": "x86_64",
                                "toolchainFingerprint": fingerprint,
                                "compileOptions": ["--jobs 1", "-O1"]}}]}),
                encoding="utf-8")
        conditions = paired.job_conditions(root)
        self.assertEqual(len(set(conditions.values())), 2, conditions)

    def test_a_later_stage_with_a_different_browser_is_not_pooled(self) -> None:
        """A browser identity recorded only on a later stage must still split."""
        root = self.root / "stage-browser"
        for name, browser in (("a", "chromium-1"), ("b", "chromium-2")):
            directory = root / name
            directory.mkdir(parents=True)
            common = {"runnerImage": "ubuntu22", "sdkVersion": "1.2.0",
                      "stdxDigest": "d", "toolchainTarget": "x86_64",
                      "compileOptions": ["--jobs 1", "-O1"]}
            (directory / "stages.json").write_text(json.dumps({"stages": [
                {"environment": {**common, "browserIdentity": "chromium-1"}},
                {"environment": {**common, "browserIdentity": browser}},
            ]}), encoding="utf-8")
        conditions = paired.job_conditions(root)
        self.assertEqual(len(set(conditions.values())), 2, conditions)

    def test_the_provenance_command_is_copyable(self) -> None:
        """A workflow name with spaces must arrive as one argument."""
        import shlex
        text = "Build Linux candidate"
        rendered = " ".join(shlex.quote(part) for part in
                            ("python3", "script.py", "--workflow", text))
        self.assertEqual(shlex.split(rendered),
                         ["python3", "script.py", "--workflow", text])

    def test_a_limit_above_one_page_is_refused(self) -> None:
        calls = []
        original = paired._run_gh
        paired._run_gh = lambda args: calls.append(args) or json.dumps(
            {"workflows": [{"id": 1, "name": "CI", "path": ".github/workflows/ci.yml"}]})
        try:
            with self.assertRaises(SystemExit):
                paired.workflow_runs("o/r", "CI", 101, None)
        finally:
            paired._run_gh = original

    def test_each_timed_workflow_maps_its_own_artifact(self) -> None:
        """`ci.yml`, `pages.yml` and `daily.yml` name their timing artifacts differently."""
        self.assertEqual(paired.job_artifact_stem("linux-x64 / Cangjie 1.2.0 STS + stdx", "ci.yml"),
                         "ci-linux-x64")
        self.assertEqual(paired.job_artifact_stem("Assemble final site", "pages.yml"),
                         "pages-assemble")
        self.assertEqual(paired.job_artifact_stem("linux-x64 / Cangjie 1.2.0 STS", "daily.yml"),
                         "daily")
        self.assertEqual(paired.job_artifact_stem("CI required", "ci.yml"), None)

    def test_an_unsupported_workflow_is_refused_not_reported_as_unknown(self) -> None:
        """A silent empty mapping would look like a legitimate "no samples" result."""
        with self.assertRaises(SystemExit):
            paired.stems_for("no-such-workflow.yml")

    def test_stems_accept_the_forms_the_cli_hands_over(self) -> None:
        """`stems_for` takes a resolved file name; a path or a bare name still works."""
        self.assertEqual(paired.stems_for("ci.yml"), paired.stems_for(".github/workflows/ci.yml"))
        self.assertIsInstance(paired.stems_for("ci.yml"), tuple)

    def test_a_partial_download_is_reported_per_artifact(self) -> None:
        """One artifact failing must be named, not hidden by the others succeeding."""
        calls = []

        def fake_run(args, **kwargs):
            import subprocess as sp
            if "artifacts/2/zip" in args[-1]:
                return sp.CompletedProcess(args, 1, b"", b"500")
            import io, zipfile
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w") as archive:
                archive.writestr("stages.json", "{}")
            return sp.CompletedProcess(args, 0, buffer.getvalue(), b"")

        artifacts = [{"id": 1, "name": "ci-timing-a-1-1"}, {"id": 2, "name": "ci-timing-b-1-1"}]
        original_gh, original_artifacts, original_run = (
            paired._run_gh, paired.matching_artifacts, subprocess.run)
        paired._run_gh = lambda args: json.dumps({"artifacts": artifacts})
        paired.matching_artifacts = lambda *a, **k: artifacts
        subprocess.run = fake_run
        try:
            failed = paired.download_evidence("o/r", 1, 1, self.root / "dl")
        finally:
            paired._run_gh, paired.matching_artifacts = original_gh, original_artifacts
            subprocess.run = original_run
        self.assertEqual(failed, ["ci-timing-b-1-1"])

    def test_a_truncated_cached_stage_record_is_not_trusted(self) -> None:
        """A half-written stages.json must be re-fetched, not parsed."""
        directory = self.root / "cached"
        directory.mkdir(parents=True)
        record = directory / "stages.json"
        record.write_text('{"stages": [{"stageId": "nat', encoding="utf-8")
        self.assertFalse(paired._readable_stage_record(record))
        record.write_text('{"stages": []}', encoding="utf-8")
        self.assertTrue(paired._readable_stage_record(record))
        record.write_text("", encoding="utf-8")
        self.assertFalse(paired._readable_stage_record(record))


if __name__ == "__main__":
    unittest.main()
