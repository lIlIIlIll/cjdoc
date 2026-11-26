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
    def producers(self, attempts, *, archive_overrides=None):
        api = API()
        outputs, archives = [], []
        roles = ("site", "source", "reading", "browser-shard-0", "browser-shard-1")
        for index, (role, attempt) in enumerate(zip(roles, attempts, strict=True), start=1):
            changes = (archive_overrides or {}).get(role, {})
            archives.append(archive(role, attempt, index, **changes))
            outputs.append(f"{role}:{attempt}:{index}:{ARCHIVE}")
        api.responses[f"actions/runs/{RUN}/artifacts?per_page=100"] = {"artifacts": archives}
        return api, outputs

    def test_selective_mixed_and_full_reruns_use_the_successful_job_outputs(self):
        for attempts in ((1, 1, 1, 1, 1), (1, 1, 1, 2, 1), (2, 2, 2, 2, 2)):
            with self.subTest(producer_attempts=attempts):
                api, outputs = self.producers(attempts)
                # Even if another attempt uploaded an archive, only the successful
                # dependency's own output authorizes what this consumer downloads.
                artifacts = api.responses[f"actions/runs/{RUN}/artifacts?per_page=100"]["artifacts"]
                alternate = 1 if attempts[-1] == 2 else 2
                artifacts.append(archive("browser-shard-1", alternate, 99))
                pages.verify_producers(api, REPO, REPO_ID, RUN, 2, COMMIT, outputs)

    def test_wrong_browser_origin_or_expired_archive_is_rejected(self):
        for changes in ({"expired": True},
                        {"workflow_run": {"id": RUN, "repository_id": REPO_ID, "head_sha": OTHER}}):
            with self.subTest(changes=changes):
                api, outputs = self.producers((1, 1, 1, 2, 1), archive_overrides={"browser-shard-0": changes})
                with self.assertRaises(SystemExit):
                    pages.verify_producers(api, REPO, REPO_ID, RUN, 2, COMMIT, outputs)

    def test_wrong_digest_id_attempt_or_incomplete_branch_set_is_rejected(self):
        api, outputs = self.producers((1, 1, 1, 2, 1))
        for bad in (outputs[:-1], outputs + outputs[-1:],
                    [*outputs[:-1], f"browser-shard-1:1:5:{SITE}"],
                    [*outputs[:-1], f"browser-shard-1:1:123:{ARCHIVE}"],
                    [*outputs[:-1], f"browser-shard-1:3:5:{ARCHIVE}"]):
            with self.subTest(bad=bad[-1]), self.assertRaises(SystemExit):
                pages.verify_producers(api, REPO, REPO_ID, RUN, 2, COMMIT, bad)

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
