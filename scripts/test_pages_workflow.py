"""Regression cases for the Pages event and artifact policies, independent of runner speed."""
import json
from pathlib import Path
import tempfile
import unittest

import pages_workflow as pages


REPO = "example/cjdoc"
REPO_ID = 11
COMMIT = "a" * 40
OTHER = "b" * 40
SITE = "c" * 64
ARCHIVE = "d" * 64
CI = 700
RUN = 701


def ci(attempt=1, **changes):
    identity = {"full_name": REPO}
    return {"id": CI, "run_attempt": attempt, "name": "CI", "path": ".github/workflows/ci.yml",
            "event": "push", "head_branch": "main", "head_sha": COMMIT, "repository": identity,
            "head_repository": identity, "status": "completed", "conclusion": "success", **changes}


def jobs(shard, attempt, **changes):
    return {"name": f"Browser shard {shard}", "run_id": RUN, "run_attempt": attempt,
            "head_sha": COMMIT, "status": "completed", "conclusion": "success", **changes}


def archive(kind, attempt, artifact_id, **changes):
    return {"name": f"cjdoc-showcase-{kind}-{RUN}-{attempt}", "id": artifact_id, "expired": False,
            "digest": f"sha256:{ARCHIVE}", "workflow_run": {"id": RUN, "repository_id": REPO_ID,
                                                         "head_sha": COMMIT}, **changes}


class API:
    def __init__(self, attempt=1):
        self.calls = []
        self.responses = {
            f"actions/runs/{CI}/attempts/{attempt}": ci(attempt),
            "git/ref/heads/main": {"object": {"sha": COMMIT}},
            f"deployments?environment=github-pages&sha={COMMIT}&per_page=100": [],
        }

    def __call__(self, path, *, paginate=True):
        self.calls.append(path)
        return self.responses[path.removeprefix(f"repos/{REPO}/")]


class PublicationPolicyTest(unittest.TestCase):
    def test_late_terminal_event_can_publish_once_after_queue_and_platform_delay(self):
        api = API()
        ci_path = f"actions/runs/{CI}/attempts/1"
        api.responses[ci_path] = ci(status="in_progress", conclusion=None)
        # The Windows job is still queued/running long past the previous window.
        # No successful completion event exists, so Pages cannot adopt this run.
        delayed = ci(status="in_progress", conclusion=None, created_at="2026-11-25T12:26:21Z")
        with self.assertRaisesRegex(SystemExit, "has not completed successfully"):
            pages.upstream(api, {"action": "completed", "workflow_run": delayed}, REPO, COMMIT)
        self.assertEqual(api.calls, [])
        finished = ci(created_at="2026-11-25T12:26:21Z", updated_at="2026-11-25T13:26:58Z")
        api.responses[ci_path] = finished
        event = {"action": "completed", "workflow_run": finished}
        identity = pages.upstream(api, event, REPO, COMMIT)
        self.assertEqual(identity, (CI, 1))
        deployments = f"deployments?environment=github-pages&sha={COMMIT}&per_page=100"
        deployment = {"id": 123, "sha": COMMIT, "environment": "github-pages"}
        api.responses[deployments] = [deployment]
        statuses = "deployments/123/statuses?per_page=100"
        api.responses[statuses] = [{"state": "in_progress", "environment_url": ""}]
        self.assertTrue(pages.deployment_needed(api, REPO, COMMIT, *identity))
        api.responses[statuses].insert(0, {"state": "success", "environment_url": "https://example.test/site/"})
        identity = pages.upstream(api, event, REPO, COMMIT)
        self.assertFalse(pages.deployment_needed(api, REPO, COMMIT, *identity))

    def test_untrusted_or_unfinished_event_does_not_query_candidates(self):
        for fields in ({"conclusion": "failure"}, {"conclusion": "cancelled"}, {"head_sha": OTHER},
                       {"name": "Release"}, {"path": ".github/workflows/other.yml"},
                       {"event": "pull_request"}, {"head_branch": "dev"},
                       {"head_repository": {"full_name": "foreign/cjdoc"}}, {"run_attempt": 0}):
            with self.subTest(fields=fields):
                api = API()
                with self.assertRaises(SystemExit):
                    pages.upstream(api, {"action": "completed", "workflow_run": ci(**fields)}, REPO, COMMIT)
                self.assertEqual(api.calls, [])

    def test_rest_rejects_wrong_attempt_sha_and_a_non_successful_conclusion(self):
        for mismatch in ({"run_attempt": 2}, {"head_sha": OTHER}, {"conclusion": "failure"},
                         {"conclusion": "cancelled"}):
            with self.subTest(mismatch=mismatch):
                api = API()
                api.responses[f"actions/runs/{CI}/attempts/1"] = ci(**mismatch)
                with self.assertRaises(SystemExit):
                    pages.deployment_needed(api, REPO, COMMIT, CI, 1)
                self.assertEqual(api.calls, [f"repos/{REPO}/actions/runs/{CI}/attempts/1"])

    def test_newer_main_cannot_be_replaced_by_an_out_of_order_event(self):
        api = API()
        api.responses["git/ref/heads/main"]["object"]["sha"] = OTHER
        self.assertFalse(pages.deployment_needed(api, REPO, COMMIT, CI, 1))
        self.assertEqual(len(api.calls), 2)


class ProducerPolicyTest(unittest.TestCase):
    def setup_run(self, shard_jobs, shard_artifacts, producer_attempt=1):
        api = API()
        api.responses[f"actions/runs/{RUN}/jobs?filter=all&per_page=100"] = {"jobs": shard_jobs}
        branches = [archive(name, producer_attempt, 200 + i)
                    for i, name in enumerate(("site", "source", "reading"))]
        api.responses[f"actions/runs/{RUN}/artifacts?per_page=100"] = {"artifacts": [*branches, *shard_artifacts]}
        outputs = [f"{name}:{producer_attempt}:{200+i}:{ARCHIVE}"
                   for i, name in enumerate(("site", "source", "reading"))]
        return api, outputs

    def test_verify_only_rerun_uses_original_site_and_every_branch(self):
        api, outputs = self.setup_run([jobs(0, 1), jobs(1, 1)],
                                      [archive("browser-shard-0", 1, 101), archive("browser-shard-1", 1, 102)])
        chosen = pages.shard_producers(api, REPO, REPO_ID, RUN, 2, COMMIT, outputs)
        self.assertEqual([(chosen[i]["id"], chosen[i]["attempt"]) for i in range(2)], [(101, 1), (102, 1)])

    def test_partial_browser_rerun_and_full_rerun_pick_actual_new_producers(self):
        for right_attempt in (1, 2):
            with self.subTest(right_attempt=right_attempt):
                api, outputs = self.setup_run(
                    [jobs(0, 1, conclusion="failure"), jobs(1, 1), jobs(0, 2),
                     *([jobs(1, 2)] if right_attempt == 2 else []), jobs(0, 3, status="queued")],
                    [archive("browser-shard-0", 1, 101), archive("browser-shard-1", 1, 102),
                     archive("browser-shard-0", 2, 103), archive("browser-shard-1", 2, 104)],
                    producer_attempt=right_attempt)
                chosen = pages.shard_producers(api, REPO, REPO_ID, RUN, 2, COMMIT, outputs)
                self.assertEqual(chosen[0]["id"], 103)
                self.assertEqual(chosen[1]["id"], 102 if right_attempt == 1 else 104)
                self.assertEqual(chosen[1]["attempt"], right_attempt)

    def test_rejects_wrong_archive_and_does_not_fall_back_from_a_failed_producer(self):
        for condition in ("new attempt failed", "wrong head", "wrong digest", "wrong id", "archive expired"):
            with self.subTest(condition=condition):
                left, right = jobs(0, 1), jobs(1, 1)
                archive0 = archive("browser-shard-0", 1, 101)
                if condition == "wrong head":
                    archive0["workflow_run"]["head_sha"] = OTHER
                if condition == "archive expired":
                    archive0["expired"] = True
                newer = [jobs(0, 2, conclusion="failure")] if condition == "new attempt failed" else []
                api, outputs = self.setup_run([left, right, *newer], [archive0, archive("browser-shard-1", 1, 102)])
                if condition == "wrong digest":
                    outputs[0] = f"site:1:200:{'f' * 64}"
                if condition == "wrong id":
                    outputs[0] = f"site:1:201:{ARCHIVE}"
                with self.assertRaises(SystemExit):
                    pages.shard_producers(api, REPO, REPO_ID, RUN, 2, COMMIT, outputs)

    def test_downloaded_shards_must_identify_the_producer_and_same_site(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = [Path(tmp) / f"shard{i}.json" for i in range(2)]
            for shard, attempt in ((0, 2), (1, 1)):
                evidence = {"shardIndex": shard, "runId": str(RUN), "runAttempt": attempt,
                            "revision": COMMIT, "siteSha256": SITE}
                paths[shard].write_text(json.dumps(evidence), encoding="utf-8")
                bind = {"shard": shard, "run_id": RUN, "attempt": attempt, "revision": COMMIT,
                        "site_digest": SITE}
                pages.verify_shard_binding(paths[shard], **bind)
                for wrong in ({"site_digest": ARCHIVE}, {"revision": OTHER}, {"attempt": 99}, {"run_id": 99}):
                    with self.assertRaisesRegex(SystemExit, "does not match its producer and site"):
                        pages.verify_shard_binding(paths[shard], **{**bind, **wrong})


if __name__ == "__main__":
    unittest.main()
