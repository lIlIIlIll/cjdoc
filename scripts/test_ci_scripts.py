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
        (self.repo / "tests/fixtures/golden-v13").mkdir(parents=True)
        (self.repo / "tests/fixtures/golden-v13/basic.docs.json").write_text("{}\n", encoding="utf-8")
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
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
             "runWallMinutes": 25.0, "runRunnerMinutes": 50.0},
        ]
        out = self.root / "cells.md"
        result = paired.report(samples, "ci.yml", out)
        self.assertEqual(sorted(result["cells"]), ["linux-x64/hit", "macos-arm64/miss"])
        text = out.read_text(encoding="utf-8")
        self.assertIn("linux-x64 / **hit**: 1 collected — NOT met", text)
        self.assertIn("macos-arm64 / **miss**: 1 collected — NOT met", text)

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
        self.assertEqual(sorted(result["cells"]), ["linux-x64/hit"])
        text = out.read_text(encoding="utf-8")
        self.assertNotIn("**ci required**", text)
        self.assertNotIn("ci required / **hit**", text)

    def test_attempts_are_enumerated_not_resolved_to_the_latest(self) -> None:
        calls = []

        def fake_samples(repository, run, run_id, attempt, cache_root):
            calls.append(attempt)
            return []

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
             "state": "unknown", "jobMinutes": 17.0,
             "runWallMinutes": 25.0, "runRunnerMinutes": 50.0},
        ]
        out = self.root / "expired.md"
        paired.report(samples, "ci.yml", out)
        text = out.read_text(encoding="utf-8")
        self.assertIn("macos-arm64 / **miss**: 0 collected — NOT met", text)
        self.assertIn("macos-arm64 / **hit**: 0 collected — NOT met", text)

    def test_an_orchestration_job_is_not_a_cache_requirement(self) -> None:
        self.assertIsNone(paired.job_artifact_stem("CI required"))
        self.assertIsNone(paired.job_artifact_stem("Classify changes"))
        self.assertEqual(paired.job_artifact_stem("linux-x64 / Cangjie"), "ci-linux-x64")

    def test_a_failed_only_shape_is_still_a_requirement(self) -> None:
        """A platform that only ever failed must report zero successful samples."""
        samples = [
            {"run": 1, "attempt": 1, "revision": "9" * 8, "event": "push",
             "job": "windows-x64 / Cangjie", "shape": "windows-x64", "conclusion": "failure",
             "state": "n/a", "jobMinutes": 5.0,
             "runWallMinutes": 25.0, "runRunnerMinutes": 50.0},
            {"run": 2, "attempt": 1, "revision": "8" * 8, "event": "push",
             "job": "linux-x64 / Cangjie", "shape": "linux-x64", "conclusion": "success",
             "state": "hit", "jobMinutes": 20.0,
             "runWallMinutes": 25.0, "runRunnerMinutes": 50.0},
        ]
        out = self.root / "failed-shape.md"
        paired.report(samples, "ci.yml", out)
        text = out.read_text(encoding="utf-8")
        self.assertIn("windows-x64 / **hit**: 0 collected — NOT met", text)
        self.assertIn("windows-x64 / **miss**: 0 collected — NOT met", text)


if __name__ == "__main__":
    unittest.main()
