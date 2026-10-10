#!/usr/bin/env python3
"""Contract tests for the CI routing, gate and diagnostic-bundle scripts."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ci_changes
import ci_diagnostics
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
        (self.repo / "tests/fixtures/golden-v11").mkdir(parents=True)
        (self.repo / "tests/fixtures/golden-v11/basic.docs.json").write_text("{}\n", encoding="utf-8")
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


if __name__ == "__main__":
    unittest.main()
