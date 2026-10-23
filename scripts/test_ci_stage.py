#!/usr/bin/env python3
"""Stage accounting and identity-gate tests for scripts/ci_stage.py."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ci_stage


class StageRecordTest(unittest.TestCase):
    def test_records_are_timed_appended_and_never_lose_history(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            records: list[dict] = []
            with ci_stage.stage("alpha", ["true"], kind="build", records=records) as handle:
                handle.record({"goldens": 9})
            with self.assertRaises(RuntimeError):
                with ci_stage.stage("beta", ["false"], kind="cli", records=records):
                    raise RuntimeError("boom")
            self.assertEqual([item["stageId"] for item in records], ["alpha", "beta"])
            self.assertEqual([item["status"] for item in records], ["passed", "failed"])
            self.assertEqual(records[0]["goldens"], 9)
            self.assertTrue(all(item["timingSource"] == "monotonic" for item in records))
            self.assertTrue(all(item["wallMs"] >= 0 for item in records))

            path = evidence / ci_stage.STAGES_FILE
            ci_stage.write_stage_evidence(path, records[:1])
            ci_stage.write_stage_evidence(path, records[1:])
            merged = ci_stage.load_records(evidence)
            self.assertEqual([item["stageId"] for item in merged], ["alpha", "beta"])
            # Re-writing the same record must not duplicate it.
            ci_stage.write_stage_evidence(path, records)
            self.assertEqual(len(ci_stage.load_records(evidence)), 2)

    def test_unknown_kind_and_field_overwrite_are_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            with ci_stage.stage("x", ["true"], kind="not-a-kind"):
                pass
        with self.assertRaises(SystemExit):
            with ci_stage.stage("x", ["true"], kind="build") as handle:
                handle.record({"wallMs": 1})

    def test_summarize_reports_stage_state(self) -> None:
        records = [{"stageId": "cli", "kind": "cli", "wallMs": 12.5, "exitCode": 0,
                    "status": "passed", "environment": {"platform": "linux-x64",
                                                        "checkoutCommit": "a" * 40,
                                                        "cache": {"cjv": "hit"}}}]
        summary = ci_stage.summarize(records)
        self.assertIn("| cli | cli | 12.5 | 0 | passed | cjv=hit |", summary)

    def test_invalid_cache_state_is_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            ci_stage.parse_cache("cjv=maybe")


class ReportedIdentityTest(unittest.TestCase):
    """The browser/font axis must be recorded by the stage that actually rendered.

    DONE-03 pairs samples under matched browser conditions, and no producer recorded
    them, so a five-sample cell could only ever be reported as "met on the recorded
    axes only". The stage now reports what it ran with; these tests pin the channel
    that carries that value into the evidence.
    """

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_a_reported_identity_lands_in_the_stage_environment(self) -> None:
        evidence = self.root / "evidence"
        script = (
            "import json, os, pathlib, sys\n"
            "path = pathlib.Path(os.environ['CJDOC_STAGE_IDENTITY_REPORT'])\n"
            "path.write_text(json.dumps({'browserVersion': '152.0',\n"
            "                            'browserIdentity': 'chromium',\n"
            "                            'fontSetDigest': 'fonts-sha'}), encoding='utf-8')\n"
        )
        code = ci_stage.run_stage("html-a11y", "browser", [sys.executable, "-c", script],
                                  evidence)
        self.assertEqual(code, 0)
        environment = ci_stage.load_records(evidence)[0]["environment"]
        self.assertEqual(environment["browserVersion"], "152.0")
        self.assertEqual(environment["browserIdentity"], "chromium")
        self.assertEqual(environment["fontSetDigest"], "fonts-sha")

    def test_a_stage_that_reports_nothing_records_empty_axes(self) -> None:
        """The keys must still be present, so a missing axis is visible as empty.

        An absent key and "recorded as empty" would be indistinguishable to a consumer
        that reads the signature positionally, and the report would silently treat a
        job that never reported as one that did.
        """
        evidence = self.root / "evidence"
        code = ci_stage.run_stage("cli", "cli", [sys.executable, "-c", "pass"], evidence)
        self.assertEqual(code, 0)
        environment = ci_stage.load_records(evidence)[0]["environment"]
        for field in ("browserVersion", "browserIdentity", "fontSetDigest"):
            self.assertIn(field, environment)
            self.assertEqual(environment[field], "")

    def test_a_stale_report_is_not_inherited_by_the_next_stage(self) -> None:
        """A report describes what a stage RAN WITH, so it cannot outlive that stage.

        Both stages write into one evidence directory, which is exactly how `check.sh`
        records the acceptance chain. Without clearing, the CLI stage that follows the
        browser stage would claim the browser identity it never used.
        """
        evidence = self.root / "evidence"
        (evidence).mkdir(parents=True)
        (evidence / ci_stage.IDENTITY_REPORT_FILE).write_text(
            json.dumps({"browserVersion": "stale"}), encoding="utf-8")
        code = ci_stage.run_stage("cli", "cli", [sys.executable, "-c", "pass"], evidence)
        self.assertEqual(code, 0)
        records = {item["stageId"]: item for item in ci_stage.load_records(evidence)}
        self.assertEqual(records["cli"]["environment"]["browserVersion"], "")

    def test_an_undeclared_field_is_rejected(self) -> None:
        """The channel may only carry fields the signature declares.

        Otherwise a stage could add `sdkVersion` and forge the very identity it is
        measured against, and the report would happily pool it with other runs.
        """
        path = self.root / "report.json"
        path.write_text(json.dumps({"sdkVersion": "9.9.9"}), encoding="utf-8")
        with self.assertRaises(SystemExit):
            ci_stage.read_reported_identity(path)

    def test_a_truncated_report_does_not_destroy_the_stage_record(self) -> None:
        """A child killed mid-write must cost the axis, not the whole evidence file.

        `run_stage` reads the report BEFORE writing `stages.json`. Aborting on a
        malformed report therefore deleted the only record the job had, and the
        artifact collector reported the job as uncollectable -- losing its timings and
        its cache state to protect one axis.
        """
        evidence = self.root / "evidence"
        script = (
            "import json, os, pathlib\n"
            "path = pathlib.Path(os.environ['CJDOC_STAGE_IDENTITY_REPORT'])\n"
            "path.write_text('{\"browserVersion\": ', encoding='utf-8')\n"
        )
        code = ci_stage.run_stage("html-a11y", "browser", [sys.executable, "-c", script],
                                  evidence)
        records = ci_stage.load_records(evidence)
        self.assertEqual(code, 0)
        self.assertEqual(len(records), 1, "the stage record must survive a bad report")
        self.assertEqual(records[0]["environment"]["browserVersion"], "")

    def test_report_identity_writes_only_declared_fields(self) -> None:
        path = self.root / "nested" / ci_stage.IDENTITY_REPORT_FILE
        ci_stage.report_identity({"browserVersion": "152.0"}, path)
        payload = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(payload["browserVersion"], "152.0")
        self.assertEqual(sorted(payload), sorted(ci_stage.REPORTABLE_IDENTITY))


class IdentityGateTest(unittest.TestCase):
    """The gate must work wherever the suite runs, so the "binary" is a real program."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        # `sys.executable` is a genuinely executable program on every platform,
        # which keeps the digest/version assertions meaningful everywhere.
        self.binary = Path(sys.executable)
        self.version_output = subprocess.run(
            [str(self.binary), "--version"], capture_output=True, text=True).stdout.strip()

    def manifest(self, *, version: str | None = None) -> Path:
        document = {
            "schemaVersion": ci_stage.BUILD_MANIFEST_SCHEMA,
            "mainBinary": {"path": "main", "sha256": ci_stage.sha256_file(self.binary),
                           "size": self.binary.stat().st_size,
                           "versionOutput": self.version_output if version is None else version},
        }
        path = self.root / "build-manifest.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        return path

    def run_gate(self, manifest: Path, *, runnable: bool = True) -> int:
        return ci_stage.verify_identity(manifest, self.binary, None, None,
                                        require_runnable=runnable)

    def test_matching_identity_passes(self) -> None:
        self.assertEqual(self.run_gate(self.manifest()), 0)

    def test_digest_and_size_mismatches_fail(self) -> None:
        document = json.loads(self.manifest().read_text(encoding="utf-8"))
        document["mainBinary"]["sha256"] = "0" * 64
        path = self.root / "bad-digest.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        self.assertEqual(self.run_gate(path), 1)

        document["mainBinary"]["sha256"] = ci_stage.sha256_file(self.binary)
        document["mainBinary"]["size"] = 1
        path = self.root / "bad-size.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        self.assertEqual(self.run_gate(path), 1)

    def test_wrong_version_fails_and_a_missing_record_fails(self) -> None:
        self.assertEqual(self.run_gate(self.manifest(version="cjdoc 9.9.9")), 1)
        document = json.loads(self.manifest().read_text(encoding="utf-8"))
        document["mainBinary"].pop("versionOutput")
        path = self.root / "no-version.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        self.assertEqual(self.run_gate(path), 1)

    def test_a_file_that_cannot_execute_is_reported_not_a_crash(self) -> None:
        """A non-program is a reported mismatch by default and allowed only explicitly."""
        not_a_program = self.root / "not-a-program"
        not_a_program.write_text("this is not an executable program\n", encoding="utf-8")
        document = json.loads(self.manifest().read_text(encoding="utf-8"))
        document["mainBinary"].update({
            "sha256": ci_stage.sha256_file(not_a_program),
            "size": not_a_program.stat().st_size})
        path = self.root / "not-a-program.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        self.assertEqual(ci_stage.verify_identity(path, not_a_program, None, None), 1)
        self.assertEqual(
            ci_stage.verify_identity(path, not_a_program, None, None, require_runnable=False), 0)

    def test_wrong_manifest_schema_is_rejected(self) -> None:
        path = self.root / "wrong.json"
        path.write_text(json.dumps({"schemaVersion": "other/1"}), encoding="utf-8")
        with self.assertRaises(SystemExit):
            ci_stage.verify_identity(path, self.binary, None, None)

    def test_run_subcommand_returns_the_child_exit_code_and_logs(self) -> None:
        evidence = self.root / "evidence"
        code = ci_stage.run_stage(
            "probe", "cli",
            [sys.executable, "-c", "import sys; print('out'); sys.stderr.write('err'); sys.exit(7)"],
            evidence)
        self.assertEqual(code, 7)
        record = ci_stage.load_records(evidence)[0]
        self.assertEqual((record["status"], record["exitCode"]), ("failed", 7))
        log = (evidence / "probe.log").read_text(encoding="utf-8")
        self.assertIn("out", log)
        self.assertIn("err", log)


class GitHubReadTest(unittest.TestCase):
    """`wallclock` reads a live API, so its transport must be reliable.

    The real failure mode: a jobs listing is more than one API page, and
    `gh api --paginate` prints one JSON document per page, which `json.loads`
    rejects. A transient EOF on a large run must also be retried, otherwise the
    evidence of an otherwise successful run is simply lost.

    The `gh` subprocess is intercepted rather than shimmed on `PATH`: a shim has
    to be an executable script, which is not portable, and on Windows the real
    `gh` was executed instead. Interception runs the same decoding and retry code
    on every platform.
    """

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.calls = 0
        self.responder = None

    def run_gh(self):
        from unittest import mock

        def fake_run(args, **_kwargs):
            self.calls += 1
            argv = [str(item) for item in (args if isinstance(args, (list, tuple)) else [args])]
            return self.responder(argv)

        with mock.patch("subprocess.run", fake_run), \
             mock.patch.object(ci_stage.time, "sleep", lambda _: None):
            return ci_stage._gh_json("repos/o/r/actions/runs/1/jobs")

    def test_concatenated_pages_are_merged(self) -> None:
        self.responder = lambda argv: subprocess.CompletedProcess(
            argv, 0, '{"jobs": [1, 2]}{"jobs": [3]}', "")
        self.assertEqual(self.run_gh(), {"jobs": [1, 2, 3]})

    def test_a_transient_failure_is_retried(self) -> None:
        def respond(argv):
            if self.calls == 1:
                return subprocess.CompletedProcess(argv, 1, "", "API rate limit")
            return subprocess.CompletedProcess(argv, 0, '{"jobs": [7]}', "")

        self.responder = respond
        self.assertEqual(self.run_gh(), {"jobs": [7]})
        self.assertEqual(self.calls, 2)

    def test_a_single_document_is_returned_unchanged(self) -> None:
        self.responder = lambda argv: subprocess.CompletedProcess(argv, 0, '{"jobs": [1]}', "")
        self.assertEqual(self.run_gh(), {"jobs": [1]})



if __name__ == "__main__":
    unittest.main()


class TransientReadTests(unittest.TestCase):
    """An empty successful `gh api` body is retried, not read as "no data"."""

    def test_an_empty_body_is_retried_before_giving_up(self):
        import subprocess
        from unittest import mock
        calls = {"n": 0}

        def fake_run(args, **kwargs):
            argv = [str(item) for item in (args if isinstance(args, (list, tuple)) else [args])]
            calls["n"] += 1
            if calls["n"] == 1:
                return subprocess.CompletedProcess(argv, 0, "", "")
            return subprocess.CompletedProcess(argv, 0, json.dumps({"total_count": 3}), "")

        with mock.patch("subprocess.run", fake_run), \
             mock.patch.object(ci_stage.time, "sleep", lambda _: None):
            payload = ci_stage._gh_json("repos/o/r/actions/runs/1", paginate=False)
        self.assertEqual(calls["n"], 2, "an empty body must be retried")
        self.assertEqual(payload, {"total_count": 3})


class NonOverlappingChainTest(unittest.TestCase):
    """Criterion 2 of issue #96 asks the artifact itself to attribute the path.

    The document used to carry only per-job durations, so the path lived in prose an
    author could compute any way they liked. The derivation here is deliberately
    narrow: a chain is claimed only where the next job actually started after the
    previous one ended, because the Jobs API exposes no dependency graph. Overlapping
    jobs therefore report a flat run rather than an invented sequence, and
    `equalsLongestJob` says so.

    The result is named for what it measures, not for the dependency critical path: a
    `needs` sibling serialized by runner availability is not on the dependency path,
    so the longer of the two is still a truthful "what happened", not an attribution.
    """

    def intervals(self, *spec: tuple[str, int, int]) -> list[tuple[str, int, int]]:
        return list(spec)

    def test_a_sequential_chain_is_longer_than_its_longest_job(self) -> None:
        result = ci_stage.non_overlapping_chain(self.intervals(
            ("native", 0, 30_000), ("cli", 30_000, 60_000), ("smoke", 60_000, 90_000)))
        self.assertEqual(result["chain"], ["native", "cli", "smoke"])
        self.assertEqual(result["wallMs"], 90_000)
        self.assertFalse(result["equalsLongestJob"])

    def test_overlapping_jobs_are_not_chained(self) -> None:
        """Two jobs that ran at the same time did not run one after the other."""
        result = ci_stage.non_overlapping_chain(self.intervals(
            ("candidate-linux", 0, 60_000), ("candidate-other", 5_000, 40_000)))
        self.assertEqual(result["chain"], ["candidate-linux"])
        self.assertTrue(result["equalsLongestJob"])
        self.assertEqual(result["longestJob"], "candidate-linux")

    def test_the_chain_prefers_the_longest_preceding_total(self) -> None:
        """A short late job must extend the longest chain, not the nearest one."""
        result = ci_stage.non_overlapping_chain(self.intervals(
            ("long", 0, 50_000), ("short", 10_000, 15_000), ("tail", 50_000, 60_000)))
        self.assertEqual(result["chain"], ["long", "tail"])

    def test_an_empty_run_claims_nothing(self) -> None:
        result = ci_stage.non_overlapping_chain([])
        self.assertEqual((result["chain"], result["wallMs"]), ([], 0))
        self.assertTrue(result["equalsLongestJob"])
        # A consumer reading the attribution must not need a special case for a run
        # whose jobs never started.
        self.assertEqual((result["longestJob"], result["longestJobMs"]), ("", 0))

    def test_the_chain_wall_belongs_to_the_chain_it_names(self) -> None:
        """A short job overlapping the long one must not set the reported total.

        The chain is still the long pair, so a maximum picked in DP order -- which
        can land on the short detour -- would print a wall that contradicts the
        chain printed beside it.
        """
        result = ci_stage.non_overlapping_chain([("A", 0, 90), ("B", 90, 1000), ("Z", 95, 96)])
        self.assertEqual(result["chain"], ["A", "B"])
        self.assertEqual(result["wallMs"], 1_000)

    def test_a_zero_length_job_does_not_shadow_the_real_chain(self) -> None:
        """A job with no duration is a point in time, not a link with cost."""
        result = ci_stage.non_overlapping_chain(self.intervals(
            ("gate", 0, 30_000), ("stamp", 30_000, 30_000), ("tail", 30_000, 40_000)))
        self.assertEqual(result["chain"], ["gate", "tail"])
        self.assertEqual(result["wallMs"], 40_000)

    def test_a_job_that_ends_when_the_next_starts_is_chained(self) -> None:
        """Handoff is inclusive: `started_at == completed_at` is still sequential."""
        result = ci_stage.non_overlapping_chain(self.intervals(
            ("first", 0, 10_000), ("second", 10_000, 20_000)))
        self.assertEqual(result["chain"], ["first", "second"])


class WallclockDocumentTest(unittest.TestCase):
    """`classify_wallclock` is the pure seam: the API payload is the only input."""

    # The Actions API always reports `status`. It is `completed` here because these
    # fixtures describe finished runs; a run that has not finished has no wall to
    # publish and is covered by its own test.
    RUN = {
        "id": 7, "name": "CI", "head_sha": "a" * 40, "run_attempt": 1,
        "status": "completed",
        "created_at": "2026-01-01T00:00:00Z",
        "run_started_at": "2026-01-01T00:00:00Z",
    }

    def job(self, name: str, start: int, end: int, attempt: int = 1) -> dict:
        """`start`/`end` are whole seconds after 00:00:00Z."""
        stamp = "2026-01-01T00:%02d:%02dZ"
        return {"name": name, "run_attempt": attempt, "steps": [],
                "started_at": stamp % divmod(start, 60),
                "completed_at": stamp % divmod(end, 60)}

    def test_a_serialised_sibling_is_part_of_the_chain_but_not_called_the_critical_path(self) -> None:
        """The chain is what ran, and its name says so rather than implying `needs`.

        `pages.yml`'s `source-reproduction` and its two `browser-shard` jobs all need
        only `assemble-site`, so none of them is on the dependency critical path. Two of
        them serialized by runner availability still spend the run's wall clock one
        after another, and a reader asking "where did the time go" needs that sequence.
        A reader asking "which `needs` edge is longest" must not be answered with it,
        which is why the field is `nonOverlappingChain` and no field claims a dependency
        path.
        """
        document = ci_stage.classify_wallclock(self.RUN, {"jobs": [
            self.job("assemble-site", 1, 3),
            self.job("source-reproduction", 3, 6),
            self.job("browser-shard-0", 6, 9)]}, 1)
        # Assert the absence FIRST: a rename back to `criticalPath` must fail here with
        # the intent stated, not with a KeyError on the name this test expects.
        self.assertNotIn("criticalPath", document)
        self.assertNotIn("dependencyPath", document)
        chain = document["nonOverlappingChain"]
        self.assertEqual(chain["chain"], ["assemble-site", "source-reproduction",
                                          "browser-shard-0"])
        self.assertEqual(chain["wallMs"], 8_000)
        self.assertFalse(chain["equalsLongestJob"])

    def test_the_document_carries_path_attribution_and_the_queue_delay(self) -> None:
        document = ci_stage.classify_wallclock(
            self.RUN, {"jobs": [self.job("build", 1, 3), self.job("accept", 3, 8)]}, 1)
        self.assertEqual(document["nonOverlappingChain"]["chain"], ["build", "accept"])
        self.assertEqual(document["queuedMs"], 1_000)
        self.assertEqual(document["jobWallMs"]["accept"], 5_000)

    def test_a_job_from_another_attempt_is_excluded(self) -> None:
        """A rerun's jobs share the listing; counting them would double the run."""
        document = ci_stage.classify_wallclock(
            self.RUN, {"jobs": [self.job("build", 1, 3), self.job("build", 4, 9, attempt=2)]}, 1)
        self.assertEqual(list(document["jobWallMs"]), ["build"])
        self.assertEqual(document["jobWallMs"]["build"], 2_000)
        self.assertFalse(document["partialRerun"])

    def test_an_older_attempt_is_actually_fetched(self) -> None:
        """`filter=latest` would make an earlier attempt classify to zeros.

        The classifier is asked for one attempt, so the transport must not decide
        which attempts exist. Requesting the latest only is invisible on a re-run:
        an earlier attempt then has no jobs to filter and produces a complete,
        plausible document in which every clock is 0.
        """
        import subprocess
        from unittest import mock

        seen: list[list[str]] = []

        def fake_run(args, **_kwargs):
            argv = [str(item) for item in (args if isinstance(args, (list, tuple)) else [args])]
            seen.append(argv)
            body = self.RUN if "/runs/7" in argv[-1] and "jobs" not in argv[-1] else {"jobs": []}
            return subprocess.CompletedProcess(argv, 0, json.dumps(body), "")

        with mock.patch("subprocess.run", fake_run), \
             mock.patch.object(ci_stage.time, "sleep", lambda _: None):
            ci_stage.wallclock("7", 1, "o/r")

        jobs_call = [argv for argv in seen if "jobs" in argv[-1]]
        self.assertEqual(len(jobs_call), 1)
        self.assertIn("filter=all", jobs_call[0][-1])

    def test_an_older_attempt_is_anchored_on_its_own_jobs(self) -> None:
        """Run-level times describe the latest attempt, so they cannot be the origin.

        Classifying attempt 1 against a run whose `run_started_at` belongs to
        attempt 2 puts every job before the origin; each interval then clamps to
        (0, 0), and the document reports a nonzero wall, a zero span and a chain
        that lost every job -- complete and plausible, and wrong.
        """
        rerun = dict(self.RUN, run_attempt=2,
                     run_started_at="2026-01-01T00:20:00Z",
                     updated_at="2026-01-01T00:30:00Z")
        document = ci_stage.classify_wallclock(
            rerun, {"jobs": [self.job("build", 1, 3), self.job("accept", 3, 8)]}, 1)
        self.assertEqual(document["jobSpanMs"], 7_000)
        self.assertEqual(document["wallMs"], 7_000)
        self.assertEqual(document["wallSource"], "attempt-jobs")
        self.assertEqual(document["nonOverlappingChain"]["chain"], ["build", "accept"])
        self.assertEqual(document["nonOverlappingChain"]["wallMs"], 7_000)
        # With `attempt-jobs` the wall IS the span, so the difference carries no
        # information about queueing; the doc says so and `queuedMs` is what reports it.
        self.assertEqual(document["wallMs"] - document["jobSpanMs"], 0)
        # Attempt 1 is queued from the run's creation, which is that attempt's start.
        self.assertEqual(document["queuedMs"], 1_000)
        # Zeroing carried records must be scoped to the latest attempt. Applied here
        # it would delete this attempt's own work and report a 7 s span beside 0.0
        # job-minutes and an empty per-job census.
        self.assertEqual(document["jobMinutes"], 0.1)
        self.assertEqual(document["jobWallMs"], {"build": 2_000, "accept": 5_000})

    def test_a_record_straddling_the_run_origin_is_not_the_anchor(self) -> None:
        """A record that started before this attempt but ended inside it is not carried.

        A re-run leaves a still-running job with its old `started_at`; once it
        finishes here its `completed_at` is after the origin, so it survives into
        `intervals` with a start before the origin. Anchoring on the earliest start
        would measure the span from before this attempt existed, so the span would
        outlast the run wall and `wall - span` would go negative.
        """
        rerun = dict(self.RUN, run_attempt=2,
                     run_started_at="2026-01-01T00:00:10Z",
                     updated_at="2026-01-01T00:00:20Z")
        straddled = {"name": "straddled", "run_attempt": 2, "steps": [],
                     "started_at": "2026-01-01T00:00:05Z",
                     "completed_at": "2026-01-01T00:00:12Z"}
        document = ci_stage.classify_wallclock(
            rerun, {"jobs": [straddled, self.job("late", 12, 19, attempt=2)]}, 2)
        self.assertEqual(document["jobSpanMs"], 9_000)
        self.assertLessEqual(document["jobSpanMs"], document["wallMs"])

    def test_a_running_job_keeps_the_steps_it_has_recorded(self) -> None:
        """A job with no `completed_at` is still running, not a carried record.

        Classifying mid-run is documented (the reproduction path names the command),
        and a running job's steps stay attached, so dropping them would throw away
        evidence the artifact can observe.
        """
        stamp = "2026-01-01T00:%02d:%02dZ"
        running = {"name": "running", "run_attempt": 1,
                   "started_at": stamp % divmod(1, 60),
                   "completed_at": None,
                   "steps": [{"name": "step-a", "started_at": stamp % divmod(1, 60),
                              "completed_at": stamp % divmod(5, 60)}]}
        document = ci_stage.classify_wallclock(
            self.RUN, {"jobs": [running, self.job("done", 2, 4)]}, 1)
        self.assertEqual(document["stepWallMs"]["running"], {"step-a": 4_000})
        self.assertEqual(document["jobWallMs"]["running"], 0)
        # The running job has no end, so it cannot lengthen the span; the completed
        # one does, and it keeps its own duration.
        self.assertEqual(document["jobSpanMs"], 2_000)
        self.assertEqual(document["jobWallMs"]["done"], 2_000)

    def test_a_rerun_does_not_measure_from_a_carried_job(self) -> None:
        """A re-run copies the previous attempt's job records with their old times.

        Anchoring the latest attempt on the earliest of those puts the origin
        before the attempt existed, so the span outlives the run and the chain
        outlasts the wall -- while the doc reads `wall - span` as the pre-start
        gap. Carried records must instead clamp to zero and drop out, and must not
        be read as this attempt's queue delay either.
        """
        rerun = dict(self.RUN, run_attempt=2,
                     created_at="2026-01-01T00:00:00Z",
                     run_started_at="2026-01-01T00:00:21Z",
                     updated_at="2026-01-01T00:00:28Z")
        carried = self.job("windows", 1, 15, attempt=2)
        fresh = [self.job("macos", 21, 25, attempt=2), self.job("gate", 25, 28, attempt=2)]
        document = ci_stage.classify_wallclock(rerun, {"jobs": [carried, *fresh]}, 2)
        self.assertEqual(document["wallSource"], "run")
        self.assertEqual(document["wallMs"], 7_000)
        self.assertEqual(document["jobSpanMs"], 7_000)
        self.assertEqual(document["nonOverlappingChain"]["chain"], ["macos", "gate"])
        self.assertEqual(document["nonOverlappingChain"]["wallMs"], 7_000)
        self.assertGreaterEqual(document["wallMs"], document["nonOverlappingChain"]["wallMs"])
        # Measured from this attempt's own start and first job, not from the carried
        # record: `created_at` is the first attempt's creation, so reading it here
        # would report the entire previous attempt as this attempt's queue delay.
        self.assertEqual(document["queuedMs"], 0)
        # The carried record must not be billed to this attempt either: its 14 minutes
        # were counted in attempt 1, and `jobMinutes` is total runner time.
        self.assertEqual(document["jobMinutes"], 0.1)
        self.assertEqual(document["jobWallMs"]["windows"], 0)
        # Give the carried record steps before asserting they are dropped: `job()`
        # builds step-less records, so the assertion above would hold just as well if
        # carried jobs kept publishing the previous attempt's step timings.
        carried["steps"] = [{"name": "step-a", "started_at": "2026-01-01T00:00:01Z",
                             "completed_at": "2026-01-01T00:00:15Z"}]
        document = ci_stage.classify_wallclock(rerun, {"jobs": [carried, *fresh]}, 2)
        self.assertNotIn("windows", document["stepWallMs"])
        self.assertEqual(document["jobMinutes"], 0.1)

        # A delay before the first fresh job proves the queue filter is doing work:
        # without it the carried start would win and report the previous attempt's
        # wait as this one's.
        later = dict(rerun, updated_at="2026-01-01T00:00:35Z")
        delayed = ci_stage.classify_wallclock(
            later, {"jobs": [carried, self.job("macos", 23, 30, attempt=2),
                             self.job("gate", 30, 35, attempt=2)]}, 2)
        self.assertEqual(delayed["queuedMs"], 2_000)
        # `wall - job span` is the pre-start gap (plus the run's tail after its last
        # job, which is zero here because `updated_at` equals the last end). A carried
        # record kept in the span would clamp to a start of 0, become the minimum, and
        # report a zero gap beside a 2 s queue.
        self.assertEqual(delayed["jobSpanMs"], 12_000)
        self.assertEqual(delayed["wallMs"] - delayed["jobSpanMs"], delayed["queuedMs"])
        self.assertEqual(delayed["jobMinutes"], 0.2)
        self.assertEqual(delayed["nonOverlappingChain"]["chain"], ["macos", "gate"])

    def test_an_attempt_beyond_the_run_is_reported_as_having_no_jobs(self) -> None:
        """A hand-passed `--attempt 3` on a two-attempt run must not borrow a wall.

        Otherwise the document carries the run-level wall beside an empty job list,
        which reads as a measured run that simply had no jobs.
        """
        payload = dict(self.RUN, run_attempt=2, run_started_at="2026-01-01T00:20:00Z",
                       updated_at="2026-01-01T00:30:00Z")
        document = ci_stage.classify_wallclock(payload, {"jobs": [self.job("a", 1, 3)]}, 3)
        self.assertEqual((document["wallMs"], document["jobSpanMs"], document["queuedMs"]),
                         (0, 0, 0))
        self.assertEqual(document["jobWallMs"], {})

    def test_the_latest_attempt_still_uses_the_run_level_wall(self) -> None:
        """The attempt-scoped origin must not replace the run wall where it is real."""
        document = ci_stage.classify_wallclock(
            self.RUN, {"jobs": [self.job("build", 1, 3)]}, 1)
        self.assertEqual(document["wallSource"], "run")

    def test_a_run_that_has_not_finished_is_measured_through_its_last_job(self) -> None:
        """The collector measures a run it is itself part of, so the run is open.

        `wallclock` is a job inside the run it classifies, so the API always reports
        that run as `in_progress` and `updated_at` is a partly-flushed snapshot that
        moves between two reads. Publishing it as `wall` claims a completion time the
        run does not have and silently drops the collector's own tail. The span is a
        lower bound: it covers completed jobs only, and `wallSource` says which.
        """
        running = dict(self.RUN, status="in_progress",
                       updated_at="2026-01-01T00:00:05Z")
        document = ci_stage.classify_wallclock(
            running, {"jobs": [self.job("build", 1, 3), self.job("gate", 4, 9)]}, 1)
        self.assertEqual(document["wallSource"], "terminal-job")
        # 5 s would be the stale snapshot, and 9 s is the last completed job. The
        # collector's own row is still open, so this is the last link it can see.
        self.assertEqual(document["wallMs"], 9_000)
        self.assertEqual(document["jobSpanMs"], 8_000)
        # The 1 s before the first job is queueing, and the wall measures it.
        self.assertEqual(document["wallMs"] - document["jobSpanMs"], 1_000)

    def test_a_run_with_no_jobs_still_produces_the_document(self) -> None:
        document = ci_stage.classify_wallclock(self.RUN, {"jobs": []}, 1)
        self.assertEqual(document["jobWallMs"], {})
        self.assertEqual(document["nonOverlappingChain"]["wallMs"], 0)
        self.assertEqual(document["queuedMs"], 0)


class WallclockClocksTest(unittest.TestCase):
    """The three clocks `docs/maintainer/ci-wallclock.md` tabulates come out of the artifact.

    A table whose columns can only be computed by hand is prose, not evidence: a
    reader cannot reproduce "job span" or "gap" from the document. These clocks are
    therefore produced by the classifier, and the doc's columns are read from it.
    """

    def run_payload(self, **overrides: str) -> dict:
        payload = {"id": 9, "name": "Deploy showcase", "head_sha": "b" * 40,
                   "run_attempt": 1, "status": "completed",
                   "created_at": "2026-01-01T00:00:00Z",
                   "run_started_at": "2026-01-01T00:00:10Z",
                   "updated_at": "2026-01-01T00:03:00Z"}
        payload.update(overrides)
        return payload

    def job(self, name: str, start: str, end: str) -> dict:
        return {"name": name, "run_attempt": 1, "steps": [],
                "started_at": f"2026-01-01T00:{start}Z",
                "completed_at": f"2026-01-01T00:{end}Z"}

    def test_the_gap_between_wall_and_job_span_is_the_queue_delay(self) -> None:
        document = ci_stage.classify_wallclock(
            self.run_payload(),
            {"jobs": [self.job("a", "00:10", "01:10"), self.job("b", "00:30", "02:10")]}, 1)
        # wall = run_started 00:10 -> updated 03:00 = 170 s; job span 00:10 -> 02:10 = 120 s.
        self.assertEqual(document["wallMs"], 170_000)
        self.assertEqual(document["jobSpanMs"], 120_000)
        self.assertEqual(document["wallMs"] - document["jobSpanMs"], 50_000)
        self.assertEqual(document["queuedMs"], 10_000)

    def test_job_minutes_do_not_hide_parallel_work(self) -> None:
        """Two overlapping 60-second jobs are 2 job-minutes on a 1-minute span."""
        document = ci_stage.classify_wallclock(
            self.run_payload(),
            {"jobs": [self.job("a", "00:10", "01:10"), self.job("b", "00:10", "01:10")]}, 1)
        self.assertEqual(document["jobSpanMs"], 60_000)
        self.assertEqual(document["jobMinutes"], 2.0)

    def test_an_unstarted_run_reports_zero_rather_than_the_queue_delay(self) -> None:
        payload = self.run_payload(run_started_at=None, updated_at=None)
        document = ci_stage.classify_wallclock(payload, {"jobs": []}, 1)
        self.assertEqual((document["wallMs"], document["jobSpanMs"], document["jobMinutes"]),
                         (0, 0, 0))
