"""Sharding control-flow tests. Synthetic fixtures, not browser evidence."""

from __future__ import annotations

from contextlib import contextmanager
import hashlib
import json
import io
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

    def merge(self, shards: list[int], *, evidence: str | None = None):
        # Every merge must target a fresh directory, so each call gets its own.
        self._merge_counter = getattr(self, "_merge_counter", 0) + 1
        name = evidence or f"merged-{self._merge_counter}"
        return browser_sharding.merge(
            self.plan_path, {index: self.root / f"shard-{index}/shard.json" for index in shards},
            self.site, self.root / name, self.root / f"{name}-receipt.json")

    def write_timings(self) -> dict[int, Path]:
        plan = load_json(self.plan_path)
        files = {}
        for index in range(plan["shardCount"]):
            path = self.root / f"timings-{index}.json"
            document = browser_sharding.timing_document({
                "results": [{"key": entry["key"], "elapsedMs": number + 0.5}
                            for number, entry in enumerate(browser_sharding.shard_cases(plan, index))]})
            path.write_text(json.dumps(document), encoding="utf-8")
            files[index] = path
        return files


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
        before = {path.name for path in self.root.iterdir()}
        receipt = self.merge([0, 1])
        merged_dir = next(path for path in self.root.iterdir()
                          if path.is_dir() and (path / "results.json").is_file())
        merged = load_json(merged_dir / "results.json")
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

    def test_merge_refuses_a_symlinked_or_existing_destination(self):
        self.run_shard(0)
        self.run_shard(1)
        shards = {index: self.root / f"shard-{index}/shard.json" for index in (0, 1)}
        # An existing directory must not be adopted: stale files would survive
        # alongside the new results.
        existing = self.root / "existing-merge"
        existing.mkdir()
        with self.assertRaisesRegex(ContractError, "new directory"):
            browser_sharding.merge(self.plan_path, shards, self.site, existing,
                                   self.root / "existing-receipt.json")
        # A destination reached through a genuine symlink must be refused.
        real = self.root / "real-target"
        real.mkdir()
        link = self.root / "linked-target"
        link.symlink_to(real, target_is_directory=True)
        with self.assertRaisesRegex(ContractError, "symlink"):
            browser_sharding.merge(self.plan_path, shards, self.site, link / "merged",
                                   self.root / "link-receipt.json")

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
                        self.merge([0, 1])
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
            self.merge([0, 1])

    def test_merge_rejects_a_stale_site(self):
        self.run_shard(0)
        self.run_shard(1)
        (self.site / "index.html").write_text('<html lang="en"><body id="home">Changed</body></html>',
                                              encoding="utf-8")
        with self.assertRaisesRegex(ContractError, "stale"):
            self.merge([0, 1])

    def test_merge_rejects_a_changed_attachment(self):
        self.run_shard(0)
        self.run_shard(1)
        image = next((self.root / "shard-0").glob("*.png"))
        image.write_bytes(home_fixture.png_bytes(8, 8))
        with self.assertRaisesRegex(ContractError, "attachment changed"):
            self.merge([0, 1])

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
            self.merge([0, 1])

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

    def test_recorded_shard_timings_merge_and_feed_the_next_plan(self):
        for index in (0, 1):
            self.run_shard(index)
        plan = load_json(self.plan_path)
        files = {index: self.root / f"shard-{index}/timings.json" for index in (0, 1)}
        history = browser_sharding.merge_timings(plan, files)
        self.assertEqual(history["schemaVersion"], browser_sharding.TIMING_SCHEMA)
        self.assertEqual([entry["key"] for entry in history["timings"]],
                         [entry["key"] for entry in plan["cases"]])
        self.assertEqual({tuple(entry["key"]) for entry in history["timings"]},
                         {tuple(entry["key"]) for entry in plan["cases"]})
        history_path = self.root / "browser-timing-history.json"
        output = io.StringIO()
        with mock.patch("sys.stdout", output):
            status = browser.shard_main([
                "merge", "--site", str(self.site), "--plan", str(self.plan_path),
                "--shard-result", f"0={self.root / 'shard-0/shard.json'}",
                "--shard-result", f"1={self.root / 'shard-1/shard.json'}",
                "--evidence", str(self.root / "merged-history"),
                "--receipt", str(self.root / "history-receipt.json"),
                "--timings", str(history_path)])
        self.assertEqual(status, 0, output.getvalue())
        self.assertIn("mode=equal-home-groups", output.getvalue())
        self.assertEqual(load_json(history_path), history)
        weighted = browser_sharding.build_plan(self.site, "synthetic-run", 2, history_path)
        self.assertEqual(weighted["assignment"]["mode"], "history-weighted")
        self.assertEqual(weighted["assignment"]["historySource"], str(history_path))
        self.assertEqual([home["ownerCase"] for home in weighted["homeKeys"]],
                         [home["ownerCase"] for home in plan["homeKeys"]])
        # The weighted schedule moves whole groups without changing which case
        # produces homepage screenshots or any case's recorded metrics.
        self.plan_path.write_text(json.dumps(weighted), encoding="utf-8")
        weighted_roots = {index: self.run_shard(index, directory=f"weighted-shard-{index}")
                          for index in (0, 1)}
        browser_sharding.merge(
            self.plan_path, {index: path / "shard.json" for index, path in weighted_roots.items()},
            self.site, self.root / "weighted-merged", self.root / "weighted-receipt.json")
        equal = load_json(self.root / "merged-history/results.json")
        balanced = load_json(self.root / "weighted-merged/results.json")
        self.assertEqual(len(equal["homepages"]), len(balanced["homepages"]))
        for before, after in zip(equal["results"], balanced["results"]):
            for field in (*browser_sharding.CASE_FIELDS, "activations", "documentNavigations", "metrics"):
                self.assertEqual(before[field], after[field], field)
            self.assertEqual([Path(picture["path"]).name for picture in before["screenshots"]],
                             [Path(picture["path"]).name for picture in after["screenshots"]])

    def test_timing_merge_rejects_duplicate_case_keys(self):
        files = self.write_timings()
        originals = {index: path.read_text() for index, path in files.items()}
        for index in (0, 1):
            with self.subTest(duplicate_shard=index):
                for shard, path in files.items():
                    path.write_text(originals[shard], encoding="utf-8")
                document = load_json(files[index])
                document["timings"].append(load_json(files[0])["timings"][0])
                files[index].write_text(json.dumps(document), encoding="utf-8")
                with self.assertRaisesRegex(ContractError, "duplicate timing case key"):
                    browser_sharding.merge_timings(load_json(self.plan_path), files)

    def test_timing_merge_requires_every_shard_document(self):
        files = self.write_timings()
        with self.assertRaisesRegex(ContractError, "needs exactly shards"):
            browser_sharding.merge_timings(load_json(self.plan_path), {0: files[0]})
        files[1].unlink()
        with self.assertRaisesRegex(ContractError, "shard 1 timings document is missing"):
            browser_sharding.merge_timings(load_json(self.plan_path), files)

    def test_timing_merge_rejects_unknown_cases(self):
        files = self.write_timings()
        document = load_json(files[0])
        document["timings"][0]["key"][0] = "unknown-feature"
        files[0].write_text(json.dumps(document), encoding="utf-8")
        with self.assertRaisesRegex(ContractError, "shard 0 timings contains unknown cases"):
            browser_sharding.merge_timings(load_json(self.plan_path), files)

    def test_timing_merge_rejects_missing_cases(self):
        files = self.write_timings()
        document = load_json(files[0])
        document["timings"].pop()
        files[0].write_text(json.dumps(document), encoding="utf-8")
        with self.assertRaisesRegex(ContractError, "shard 0 timings is missing cases"):
            browser_sharding.merge_timings(load_json(self.plan_path), files)

    def test_timing_merge_rejects_wrong_schema(self):
        files = self.write_timings()
        document = load_json(files[0])
        document["schemaVersion"] = "cjdoc.browser-timing/0"
        files[0].write_text(json.dumps(document), encoding="utf-8")
        with self.assertRaisesRegex(ContractError, "unexpected schemaVersion"):
            browser_sharding.merge_timings(load_json(self.plan_path), files)

    def test_timing_merge_rejects_negative_elapsed_ms(self):
        files = self.write_timings()
        document = load_json(files[0])
        document["timings"][0]["elapsedMs"] = -0.001
        files[0].write_text(json.dumps(document), encoding="utf-8")
        with self.assertRaisesRegex(ContractError, "invalid elapsedMs.*finite nonnegative number"):
            browser_sharding.merge_timings(load_json(self.plan_path), files)

    def test_timing_merge_rejects_nonnumeric_nonfinite_and_malformed_entries(self):
        files = self.write_timings()
        original = files[0].read_text()
        for value in (True, "100", None, float("nan"), float("inf"), 1e309):
            with self.subTest(elapsedMs=value):
                document = json.loads(original)
                document["timings"][0]["elapsedMs"] = value
                files[0].write_text(json.dumps(document), encoding="utf-8")
                with self.assertRaisesRegex(ContractError, "invalid elapsedMs|nonfinite JSON"):
                    browser_sharding.merge_timings(load_json(self.plan_path), files)
        for key in (None, [["nested"]], ["short"], [1] * len(browser_sharding.CASE_FIELDS)):
            with self.subTest(key=key):
                document = json.loads(original)
                document["timings"][0]["key"] = key
                files[0].write_text(json.dumps(document), encoding="utf-8")
                with self.assertRaisesRegex(ContractError, "malformed case key"):
                    browser_sharding.merge_timings(load_json(self.plan_path), files)

    def test_plan_rejects_partial_unknown_or_duplicate_history(self):
        files = self.write_timings()
        history = browser_sharding.merge_timings(load_json(self.plan_path), files)
        history_path = self.root / "invalid-history.json"
        for mutate, pattern in (
            (lambda doc: doc["timings"].pop(), "missing cases"),
            (lambda doc: doc["timings"][0]["key"].__setitem__(0, "unknown"), "unknown cases"),
            (lambda doc: doc["timings"].append(doc["timings"][0]), "duplicate timing case key"),
        ):
            with self.subTest(pattern=pattern):
                document = json.loads(json.dumps(history))
                mutate(document)
                history_path.write_text(json.dumps(document), encoding="utf-8")
                with self.assertRaisesRegex(ContractError, pattern):
                    browser_sharding.build_plan(self.site, "synthetic-run", 2, history_path)



class HistoricalTimingBalanceTests(unittest.TestCase):
    def test_real_pages_timings_are_at_least_as_balanced_as_equal_groups(self):
        # Captured from lIlIIlIll/cjdoc Pages run 38332333489, attempt 1:
        # gh run download 38332333489 -n cjdoc-showcase-browser-shard-0-38332333489-1 -D <shard-0>
        # gh run download 38332333489 -n cjdoc-showcase-browser-shard-1-38332333489-1 -D <shard-1>
        # The payloads are browser-shard-<N>/timings.json. homeKey was joined
        # by the full six-field identity from that run's browser-plan.json.
        # Full downloads timed out locally; ranged reads retrieved these exact
        # ZIP members. No generated or rescaled timing values are substituted.
        path = ROOT / "tests/showcase_contract/browser_timing_pages_38332333489_1.json"
        history = load_json(path)
        self.assertEqual(history["source"]["runId"], "38332333489")
        self.assertEqual(history["source"]["runAttempt"], 1)
        costs = browser_sharding.history_costs(path)
        groups: dict[tuple, list] = {}
        for entry in history["timings"]:
            groups.setdefault(tuple(entry["homeKey"]), []).append(tuple(entry["key"]))
        self.assertEqual(len(costs), 324)
        self.assertEqual(len(groups), 18)
        equal, equal_mode = browser_sharding.assign_home_groups(groups, {})
        weighted, weighted_mode = browser_sharding.assign_home_groups(groups, costs)
        self.assertEqual(equal_mode, "equal-home-groups")
        self.assertEqual(weighted_mode, "history-weighted")

        def loads(assignment: dict[tuple, int]) -> list[float]:
            return [sum(costs[key] for home, keys in groups.items()
                        if assignment[home] == shard for key in keys)
                    for shard in range(browser_sharding.SHARD_COUNT)]

        equal_max, weighted_max = max(loads(equal)), max(loads(weighted))
        self.assertEqual(round(equal_max, 3), 332003.311)
        self.assertLessEqual(weighted_max, equal_max,
                             f"real Pages history regressed balance: {weighted_max} > {equal_max}")



@contextmanager
def _identity_context():
    yield ""


if __name__ == "__main__":
    unittest.main()
