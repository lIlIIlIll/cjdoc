"""CI-05.1 candidate readiness: resolution, marker binding and fail-closed paths.

These tests use a scripted `gh` stand-in so the decision logic runs for real
while the API is deterministic. The negative cases matter most: an ambiguous,
contradictory, expired or foreign state must fall back or fail rather than pick
a candidate by luck.
"""

from __future__ import annotations

import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from scripts import ci_candidate_source as source  # noqa: E402

COMMIT = "a" * 40
TREE = "b" * 40


def _fake_gh(tmp: Path, *, workflows=None, attempts=None, artifacts=None, runs=None):
    """Intercept the `gh` subprocess instead of installing a shell shim.

    A PATH shim has to be an executable script, which is not portable: on Windows
    the `.py` file is not runnable as `gh`, so the real `gh` was executed and the
    tests failed for the wrong reason. Patching `subprocess.run` runs the same
    production code path (argument handling, JSON decoding, retry) on every
    platform.
    """
    import subprocess

    log: list[list[str]] = []
    state = {
        "api": {
            f"repos/o/r/actions/workflows/ci.yml/runs?head_sha={COMMIT}&per_page=100":
                {"workflow_runs": runs or []},
            **{path: {"artifacts": items} for path, items in (artifacts or {}).items()},
        },
        "attempts": attempts or {},
    }

    def fake_run(args, **kwargs):
        argv = [str(item) for item in (args if isinstance(args, (list, tuple)) else [args])]
        log.append(argv)
        if argv[:1] == ["gh"] and argv[1:2] == ["api"]:
            path = next(item for item in argv[2:] if not item.startswith("-"))
            payload = state["api"].get(path, {})
            return subprocess.CompletedProcess(argv, 0, json.dumps(payload), "")
        if argv[:3] == ["gh", "run", "view"]:
            run_id = argv[3]
            attempt = argv[argv.index("--attempt") + 1] if "--attempt" in argv else "1"
            payload = state["attempts"].get(f"{run_id}/{attempt}", {})
            return subprocess.CompletedProcess(argv, 0, json.dumps(payload), "")
        return subprocess.CompletedProcess(argv, 1, "", f"unsupported: {argv}")

    return fake_run, log


def _marker(run_id: int, attempt: int, migration: dict | None = None) -> dict:
    return {"id": 1, "name": source.marker_name(run_id, attempt), "expired": False,
            "size_in_bytes": 512, "workflow_run": {"id": run_id}, **(migration or {})}


class ResolveTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def require_ready(self, runs, artifacts, attempts):
        fake_run, _ = _fake_gh(self.root, runs=runs, artifacts=artifacts, attempts=attempts)
        with mock.patch("subprocess.run", fake_run):
            return source.require_ready("o/r", COMMIT, "", "", "push")

    def resolve(self, runs, artifacts, attempts, **kwargs):
        fake_run, _ = _fake_gh(self.root, runs=runs, artifacts=artifacts, attempts=attempts)
        with mock.patch("subprocess.run", fake_run), \
             mock.patch.object(source.time, "sleep", lambda _: None):
            return source.resolve("o/r", COMMIT, "push", "", "", 0, 1, log=lambda _: None)

    def test_adopts_the_single_ready_candidate(self):
        runs = [{"id": 77, "name": "CI", "run_attempt": 1, "status": "completed", "conclusion": "success"}]
        artifacts = {f"repos/o/r/actions/artifacts?name={source.marker_name(77, 1)}":
                     [_marker(77, 1)],
                     "repos/o/r/actions/artifacts?name=cjdoc-linux-candidate-77-1":
                     [{"id": 9, "expired": False}]}
        attempts = {"77/1": {"headSha": COMMIT, "status": "completed", "conclusion": "success"}}
        resolved = self.resolve(runs, artifacts, attempts)
        self.assertTrue(resolved["reuse"])
        self.assertEqual(resolved["candidateSource"], "ci-artifact")
        self.assertEqual(resolved["runId"], 77)
        self.assertEqual(resolved["artifactName"], "cjdoc-linux-candidate-77-1")

    def test_ambiguous_ready_candidates_fall_back(self):
        runs = [{"id": 77, "name": "CI", "run_attempt": 1, "status": "completed", "conclusion": "success"},
                {"id": 78, "name": "CI", "run_attempt": 1, "status": "completed", "conclusion": "success"}]
        artifacts = {}
        for run_id in (77, 78):
            artifacts[f"repos/o/r/actions/artifacts?name={source.marker_name(run_id, 1)}"] = \
                [_marker(run_id, 1)]
            artifacts[f"repos/o/r/actions/artifacts?name=cjdoc-linux-candidate-{run_id}-1"] = \
                [{"id": run_id, "expired": False}]
        attempts = {f"{run_id}/1": {"headSha": COMMIT, "status": "completed",
                                    "conclusion": "success"} for run_id in (77, 78)}
        resolved = self.resolve(runs, artifacts, attempts)
        self.assertFalse(resolved["reuse"])
        self.assertIn("exactly one ready CI candidate", resolved["reason"])

    def test_pull_request_never_reuses(self):
        resolved = source.resolve("o/r", COMMIT, "pull_request", "", "", 0, 1, log=lambda _: None)
        self.assertFalse(resolved["reuse"])
        self.assertEqual(resolved["candidateSource"], "local-build")

    def test_dispatch_without_run_id_builds_locally(self):
        resolved = source.resolve("o/r", COMMIT, "workflow_dispatch", "", "", 0, 1,
                                  log=lambda _: None)
        self.assertFalse(resolved["reuse"])

    def test_a_candidate_without_a_live_artifact_is_not_ready(self):
        runs = [{"id": 77, "name": "CI", "run_attempt": 1, "status": "completed", "conclusion": "success"}]
        artifacts = {f"repos/o/r/actions/artifacts?name={source.marker_name(77, 1)}":
                     [_marker(77, 1)],
                     "repos/o/r/actions/artifacts?name=cjdoc-linux-candidate-77-1":
                     [{"id": 9, "expired": True}]}
        attempts = {"77/1": {"headSha": COMMIT, "status": "completed", "conclusion": "success"}}
        resolved = self.resolve(runs, artifacts, attempts)
        self.assertFalse(resolved["reuse"])

    def test_a_marker_from_another_commit_is_ignored(self):
        runs = [{"id": 77, "name": "CI", "run_attempt": 1, "status": "completed", "conclusion": "success"}]
        artifacts = {f"repos/o/r/actions/artifacts?name={source.marker_name(77, 1)}":
                     [_marker(77, 1)],
                     "repos/o/r/actions/artifacts?name=cjdoc-linux-candidate-77-1":
                     [{"id": 9, "expired": False}]}
        attempts = {"77/1": {"headSha": "c" * 40, "status": "completed", "conclusion": "success"}}
        resolved = self.resolve(runs, artifacts, attempts)
        self.assertFalse(resolved["reuse"])

    def test_a_still_running_matrix_is_adopted_but_cannot_publish(self):
        # The crux of CI-05.1: the marker exists, so the candidate may be consumed
        # while Windows/macOS are still running...
        runs = [{"id": 77, "name": "CI", "run_attempt": 1, "status": "in_progress",
                 "conclusion": None}]
        artifacts = {f"repos/o/r/actions/artifacts?name={source.marker_name(77, 1)}":
                     [_marker(77, 1)],
                     "repos/o/r/actions/artifacts?name=cjdoc-linux-candidate-77-1":
                     [{"id": 9, "expired": False}]}
        attempts = {"77/1": {"headSha": COMMIT, "status": "in_progress", "conclusion": None}}
        resolved = self.resolve(runs, artifacts, attempts)
        self.assertTrue(resolved["reuse"], resolved)
        self.assertEqual(resolved["runConclusion"], None)
        # ...but it must never publish until the run really succeeded.
        with self.assertRaises(source.ResolutionError):
            self.require_ready(runs, artifacts, attempts)

    def test_a_run_that_concluded_with_failure_is_not_adopted(self):
        runs = [{"id": 77, "name": "CI", "run_attempt": 1, "status": "completed",
                 "conclusion": "failure"}]
        artifacts = {f"repos/o/r/actions/artifacts?name={source.marker_name(77, 1)}":
                     [_marker(77, 1)],
                     "repos/o/r/actions/artifacts?name=cjdoc-linux-candidate-77-1":
                     [{"id": 9, "expired": False}]}
        attempts = {"77/1": {"headSha": COMMIT, "status": "completed",
                             "conclusion": "failure"}}
        resolved = self.resolve(runs, artifacts, attempts)
        self.assertFalse(resolved["reuse"])
        self.assertIn("concluded failure", resolved["reason"])

    def test_a_run_that_only_succeeded_on_a_later_attempt_is_not_reused(self):
        runs = [{"id": 77, "name": "CI", "run_attempt": 2, "status": "completed", "conclusion": "success"}]
        artifacts = {f"repos/o/r/actions/artifacts?name={source.marker_name(77, 2)}":
                     [_marker(77, 2)]}
        attempts = {"77/2": {"headSha": COMMIT, "status": "completed",
                             "conclusion": "failure"}}
        resolved = self.resolve(runs, artifacts, attempts)
        self.assertFalse(resolved["reuse"])


class MarkerBindingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tar = self.root / "cjdoc-linux-candidate.tar"
        self.tar.write_bytes(b"candidate bytes")
        self.marker_dir = self.root / "marker"

    def publish(self) -> Path:
        return source.mark("o/r", 5, 1, COMMIT, TREE, "cjdoc-linux-candidate-5-1",
                           self.tar, self.marker_dir)

    def verify(self, *, commit: str = COMMIT, artifact: str = "cjdoc-linux-candidate-5-1",
               marker: dict | None = None):
        fake_run, _ = _fake_gh(self.root, artifacts={
            f"repos/o/r/actions/artifacts?name={source.marker_name(5, 1)}": [marker or _marker(5, 1)]})
        with mock.patch("subprocess.run", fake_run):
            return source.verify_marker("o/r", 5, 1, self.marker_dir, self.tar, artifact, commit)

    def test_round_trip_binds_the_candidate_bytes(self):
        self.publish()
        document = self.verify()
        self.assertEqual(document["candidateTarSha256"], source.sha256_file(self.tar))
        self.assertEqual(document["tree"], TREE)

    def test_marker_rejects_a_changed_candidate(self):
        self.publish()
        self.tar.write_bytes(b"different bytes")
        with self.assertRaises(source.ResolutionError):
            self.verify()

    def test_marker_rejects_another_commit(self):
        self.publish()
        with self.assertRaises(source.ResolutionError):
            self.verify(commit="d" * 40)

    def test_marker_rejects_a_missing_live_artifact(self):
        self.publish()
        with self.assertRaises(source.ResolutionError):
            self.verify(marker={"id": 1, "name": "someone-elses-marker", "expired": False,
                                "workflow_run": {"id": 5}})

    def test_marker_rejects_a_short_commit(self):
        with self.assertRaises(source.ResolutionError):
            source.mark("o/r", 5, 1, "abc", TREE, "cjdoc-linux-candidate-5-1",
                        self.tar, self.marker_dir)

    def test_marker_rejects_a_missing_candidate_tar(self):
        with self.assertRaises(source.ResolutionError):
            source.mark("o/r", 5, 1, COMMIT, TREE, "cjdoc-linux-candidate-5-1",
                        self.root / "absent.tar", self.marker_dir)


class RequireReadyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def require(self, runs, artifacts, attempts, **kwargs):
        fake_run, _ = _fake_gh(self.root, runs=runs, artifacts=artifacts, attempts=attempts)
        with mock.patch("subprocess.run", fake_run):
            return source.require_ready("o/r", COMMIT, "", "", "push")

    def test_requires_a_ready_candidate(self):
        runs = [{"id": 77, "name": "CI", "run_attempt": 1, "status": "completed", "conclusion": "success"}]
        artifacts = {f"repos/o/r/actions/artifacts?name={source.marker_name(77, 1)}":
                     [_marker(77, 1)],
                     "repos/o/r/actions/artifacts?name=cjdoc-linux-candidate-77-1":
                     [{"id": 9, "expired": False}]}
        attempts = {"77/1": {"headSha": COMMIT, "status": "completed", "conclusion": "success"}}
        self.assertEqual(self.require(runs, artifacts, attempts)["runId"], 77)

    def test_a_later_matrix_failure_leaves_the_matrix_without_a_ready_candidate(self):
        # The Linux candidate is live but the CI run as a whole failed, so its
        # attempt does not report success and publication must be refused.
        runs = [{"id": 77, "name": "CI", "run_attempt": 1, "status": "completed", "conclusion": "failure"}]
        artifacts = {f"repos/o/r/actions/artifacts?name={source.marker_name(77, 1)}":
                     [_marker(77, 1)],
                     "repos/o/r/actions/artifacts?name=cjdoc-linux-candidate-77-1":
                     [{"id": 9, "expired": False}]}
        attempts = {"77/1": {"headSha": COMMIT, "status": "completed", "conclusion": "failure"}}
        with self.assertRaises(source.ResolutionError):
            self.require(runs, artifacts, attempts)

    def test_no_ci_run_at_all_is_refused(self):
        with self.assertRaises(source.ResolutionError):
            self.require([], {}, {})


if __name__ == "__main__":
    unittest.main()
