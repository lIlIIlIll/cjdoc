"""Sharding control-flow tests. Synthetic fixtures, not browser evidence."""

from __future__ import annotations

from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests/showcase_contract"))

import home_fixture
from showcase_contract import browser, browser_sharding
from showcase_contract.browser import screenshot_name
from showcase_contract.site import ContractError, Site, canonical_json, load_json


class FakeBrowser:
    version = "synthetic-1.0"

    def new_context(self, **_):
        raise AssertionError("patching failed: a real context was requested")

    def close(self):
        pass


@contextmanager
def fake_playwright():
    class Chromium:
        def launch(self, **_):
            return FakeBrowser()

    class Playwright:
        chromium = Chromium()

    yield Playwright()


def fake_exercise(browser_handle, target, key, base, site, output: Path, homes: dict) -> dict:
    """Mirror the real recorder's attachment and activation bookkeeping."""
    from showcase_contract.scenarios import SCENARIOS

    scenario = SCENARIOS[key[2]]
    home_key = (target["locale"], scenario[2], scenario[3], key[3], scenario[-1])
    home_images = []
    if home_key not in homes:
        for theme in ("light", "dark"):
            name = screenshot_name((*home_key, "homepage", theme))
            (output / name).write_bytes(home_fixture.png_bytes(scenario[2], scenario[3]))
            home_images.append({"theme": theme, "path": name,
                                "sha256": hashlib.sha256((output / name).read_bytes()).hexdigest()})
        homes[home_key] = {"locale": target["locale"], "mode": key[3], "prefix": scenario[-1],
                           "viewport": {"width": scenario[2], "height": scenario[3]},
                           "screenshots": home_images}
    pictures = []
    for theme in ("light", "dark"):
        name = screenshot_name((*key, theme))
        (output / name).write_bytes(home_fixture.png_bytes(scenario[2], scenario[3]))
        pictures.append({"theme": theme, "path": name,
                         "sha256": hashlib.sha256((output / name).read_bytes()).hexdigest()})
    metrics = {"viewport": {"width": scenario[2], "height": scenario[3]},
               "landing": {"memberCount": 25, "firstScreenMembers": 2, "listHeight": 100,
                           "compactRowHeight": 40, "contentTop": 10,
                           "horizontalOverflow": False, "scrollY": 0},
               "scrollEvents": 0, "scrollDistance": 0,
               "queryMs": [10] if scenario[0] in {"members", "search"} else [],
               "expandMs": [10] if scenario[0] in {"members", "contracts", "resources"} else [],
               "homepageActivations": 1, "homepageDocumentNavigations": 1}
    return {"featureId": key[0], "targetId": key[1], "scenarioId": key[2], "mode": key[3],
            "locale": key[4], "version": key[5], "status": "passed", "entry": "index.html",
            "href": target["resolved"]["href"], "activations": 1, "documentNavigations": 1,
            "assertions": [f"synthetic assertion for {' / '.join(key)}"],
            "screenshot": {name: pictures[0][name] for name in ("path", "sha256")},
            "screenshots": pictures, "metrics": metrics}


class ShardingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fixture = home_fixture.HomeFixture(self.root)
        self.site = self.fixture.site
        self.plan_path = self.root / "plan.json"
        self.write_plan()
        # Patch only the browser boundary; every sharding decision stays real.
        for name, value in (
            ("exercise", fake_exercise),
            ("extract_archive", lambda *_args, **_kwargs: Site(self.site)),
        ):
            patcher = mock.patch.object(browser, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        serve_patcher = mock.patch.object(browser, "serve", lambda *a, **k: _identity_context())
        serve_patcher.start()
        self.addCleanup(serve_patcher.stop)
        module = type(sys)("playwright.sync_api")
        module.sync_playwright = fake_playwright
        for patcher in (mock.patch.dict(sys.modules, {"playwright.sync_api": module}),
                        mock.patch.object(browser.importlib.metadata, "version", lambda _: "synthetic-1.0")):
            patcher.start()
            self.addCleanup(patcher.stop)

    def write_plan(self, **overrides) -> dict:
        plan = browser_sharding.build_plan(self.site, "synthetic-run", 2)
        plan.update(overrides)
        self.plan_path.write_text(json.dumps(plan, ensure_ascii=False), encoding="utf-8")
        return plan

    def run_shard(self, index: int, *, run_id: str = "synthetic-run", run_attempt: int = 1,
                  directory: str | None = None) -> Path:
        evidence = self.root / (directory or f"shard-{index}")
        browser.run(self.site, evidence, None, shard=(load_json(self.plan_path), index, run_id, run_attempt))
        return evidence

    def merge(self, shards: list[int], *, evidence: str = "merged"):
        return browser_sharding.merge(
            self.plan_path, {index: self.root / f"shard-{index}/shard.json" for index in shards},
            self.site, self.root / evidence, self.root / f"{evidence}-receipt.json")

    def test_plan_is_deterministic_and_groups_stay_whole(self):
        first = browser_sharding.build_plan(self.site, "synthetic-run", 2)
        second = browser_sharding.build_plan(self.site, "synthetic-run", 2)
        self.assertEqual(first["planSha256"], second["planSha256"])
        self.assertEqual(first["shardCount"], 2)
        self.assertEqual(a := {entry["shard"] for entry in first["cases"]}, {0, 1})
        by_home: dict[tuple, set[int]] = {}
        for entry in first["cases"]:
            by_home.setdefault(tuple(entry["homeKey"]), set()).add(entry["shard"])
        self.assertTrue(all(len(shards) == 1 for shards in by_home.values()),
                        "a homepage group was split across shards")
        registered = list(browser.registered_cases(load_json(self.site / "showcase-features.json")))
        ordered = [tuple(entry["key"]) for entry in first["cases"]]
        self.assertEqual([key for key in registered if key[0] == ordered[0][0]][:2],
                         ordered[:2], "shard plan must preserve registration order")

    def test_plan_rejects_a_shard_count_other_than_two(self):
        with self.assertRaisesRegex(ContractError, "exactly 2 shards"):
            browser_sharding.build_plan(self.site, "synthetic-run", 3)

    def test_two_shards_reproduce_the_single_process_case_set(self):
        self.run_shard(0)
        self.run_shard(1)
        receipt = self.merge([0, 1])
        merged = load_json(self.root / "merged/results.json")
        expected = browser.registered_cases(load_json(self.site / "showcase-features.json"))
        self.assertEqual({tuple(case[field] for field in browser_sharding.CASE_FIELDS)
                          for case in merged["results"]}, set(expected))
        self.assertEqual(len(merged["results"]), len(expected))
        self.assertEqual(len(merged["homepages"]), len(
            browser_sharding.build_plan(self.site, "synthetic-run", 2)["homeKeys"]))
        for case in merged["results"]:
            self.assertTrue(case["assertions"])
            self.assertTrue(case["screenshots"])
            self.assertGreaterEqual(case["activations"], 1)
            self.assertTrue(case["screenshot"]["path"].startswith(("shard-0/", "shard-1/")))
        self.assertEqual(receipt["schemaVersion"], browser_sharding.MERGE_SCHEMA)
        self.assertEqual(len(receipt["shards"]), 2)

    def test_run_refuses_an_existing_evidence_directory(self):
        evidence = self.root / "existing"
        evidence.mkdir()
        (evidence / "results.json").write_text("stale")
        with self.assertRaisesRegex(ContractError, "new directory"):
            browser.run(self.site, evidence, None,
                        shard=(load_json(self.plan_path), 0, "synthetic-run", 1))
        self.assertEqual((evidence / "results.json").read_text(), "stale")

    def test_merge_rejects_missing_duplicate_stale_and_tampered_shards(self):
        self.run_shard(0)
        self.run_shard(1)
        cases = (
            ([0], "exactly shards"),
            ([0, 0], "exactly shards"),
        )
        for shards, pattern in cases:
            with self.subTest(shards=shards), self.assertRaisesRegex(ContractError, pattern):
                browser_sharding.merge(
                    self.plan_path, {index: self.root / f"shard-{index}/shard.json" for index in shards},
                    self.site, self.root / "merged-bad", self.root / "receipt-bad.json")
        for mutate, pattern in (
            (lambda shard: shard.update(planSha256="0" * 64), "different plan"),
            (lambda shard: shard.update(siteSha256="0" * 64), "identity mismatch"),
            (lambda shard: shard.update(manifestSha256="0" * 64), "identity mismatch"),
            (lambda shard: shard.update(status="failed"), "did not pass"),
            (lambda shard: shard.update(runId="other-run"), "different run"),
            (lambda shard: shard.update(expectedCases=shard["expectedCases"][:-1]), "expected cases"),
        ):
            with self.subTest(mutation=pattern):
                shard_path = self.root / "shard-0/shard.json"
                original = shard_path.read_text()
                shard = json.loads(original)
                mutate(shard)
                shard_path.write_text(json.dumps(shard), encoding="utf-8")
                try:
                    with self.assertRaisesRegex(ContractError, pattern):
                        self.merge([0, 1], evidence="merged-tampered")
                finally:
                    shard_path.write_text(original, encoding="utf-8")

    def test_merge_rejects_a_case_owned_by_another_shard(self):
        self.run_shard(0)
        self.run_shard(1)
        originals = {index: (self.root / f"shard-{index}/shard.json").read_text() for index in (0, 1)}
        for index in (0, 1):
            for path, text in originals.items():
                (self.root / f"shard-{path}/shard.json").write_text(text, encoding="utf-8")
            path = self.root / f"shard-{index}/shard.json"
            shard = json.loads(path.read_text())
            foreign = json.loads((self.root / f"shard-{1 - index}/shard.json").read_text())["results"][0]
            shard["results"].append(foreign)
            shard["completedCases"].append([foreign[field] for field in browser_sharding.CASE_FIELDS])
            path.write_text(json.dumps(shard), encoding="utf-8")
            with self.assertRaisesRegex(ContractError, "another shard"):
                self.merge([0, 1], evidence=f"merged-foreign-{index}")
        for path, text in originals.items():
            (self.root / f"shard-{path}/shard.json").write_text(text, encoding="utf-8")

    def test_merge_rejects_a_duplicated_case(self):
        self.run_shard(0)
        self.run_shard(1)
        path = self.root / "shard-1/shard.json"
        shard = json.loads(path.read_text())
        shard["results"].append(shard["results"][0])
        path.write_text(json.dumps(shard), encoding="utf-8")
        with self.assertRaisesRegex(ContractError, "duplicate case"):
            self.merge([0, 1], evidence="merged-duplicate")

    def test_merge_rejects_a_stale_site(self):
        self.run_shard(0)
        self.run_shard(1)
        (self.site / "index.html").write_text('<html lang="en"><body id="home">Changed</body></html>',
                                              encoding="utf-8")
        with self.assertRaisesRegex(ContractError, "stale"):
            self.merge([0, 1], evidence="merged-stale")

    def test_merge_rejects_a_changed_attachment(self):
        self.run_shard(0)
        self.run_shard(1)
        image = next((self.root / "shard-0").glob("*.png"))
        image.write_bytes(home_fixture.png_bytes(8, 8))
        with self.assertRaisesRegex(ContractError, "attachment changed"):
            self.merge([0, 1], evidence="merged-tampered-image")

    def test_merge_rejects_a_non_png_attachment(self):
        self.run_shard(0)
        self.run_shard(1)
        path = self.root / "shard-0/shard.json"
        shard = json.loads(path.read_text())
        image = next((self.root / "shard-0").glob("*.png"))
        shard["attachments"][0]["relativePath"] = image.name
        shard["attachments"][0]["sha256"] = hashlib.sha256(image.read_bytes()).hexdigest()
        image.write_bytes(b"not a png at all")
        shard["attachments"][0]["sha256"] = hashlib.sha256(image.read_bytes()).hexdigest()
        path.write_text(json.dumps(shard), encoding="utf-8")
        with self.assertRaisesRegex(ContractError, "not a PNG"):
            self.merge([0, 1], evidence="merged-notpng")

    def test_merge_rejects_a_shard_result_symlink(self):
        self.run_shard(0)
        self.run_shard(1)
        link = self.root / "shard-link.json"
        link.symlink_to(self.root / "shard-1/shard.json")
        with self.assertRaisesRegex(ContractError, "missing or a symlink"):
            browser_sharding.merge(self.plan_path, {0: self.root / "shard-0/shard.json", 1: link},
                                   self.site, self.root / "merged-link", self.root / "receipt-link.json")

    def test_run_rejects_a_plan_for_another_run(self):
        with self.assertRaisesRegex(ContractError, "does not own|for run|plan"):
            browser.run(self.site, self.root / "wrong-run", None,
                        shard=(load_json(self.plan_path), 0, "different-run", 1))

    def test_plan_history_produces_a_weighted_assignment(self):
        history = {"schemaVersion": browser_sharding.TIMING_SCHEMA,
                   "timings": [{"key": list(entry["key"]), "elapsedMs": 1000.0 * index}
                               for index, entry in enumerate(
                                   browser_sharding.build_plan(self.site, "seeded", 2)["cases"])]}
        history_path = self.root / "history.json"
        history_path.write_text(json.dumps(history), encoding="utf-8")
        weighted = browser_sharding.build_plan(self.site, "synthetic-run", 2, history_path)
        self.assertEqual(weighted["assignment"]["mode"], "history-weighted")
        self.assertEqual({entry["shard"] for entry in weighted["cases"]}, {0, 1})


@contextmanager
def _identity_context():
    yield ""


if __name__ == "__main__":
    unittest.main()
