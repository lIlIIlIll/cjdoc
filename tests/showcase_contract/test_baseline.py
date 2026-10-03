"""Scope-regression tests; synthetic manifests are not browser evidence."""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from showcase_contract.baseline import BASELINE_SCHEMA, check_baseline, validate_baseline
from showcase_contract.contract import MANIFEST_SCHEMA, PLAN_SCHEMA
from showcase_contract.site import ContractError, canonical_json, load_json


def resolved_manifest(plan: dict) -> dict:
    normalized = {**plan, "features": [{**feature, "inputs": sorted(feature["inputs"])}
                                       for feature in plan["features"]]}
    features = []
    for feature in plan["features"]:
        features.append({**feature,
                         "inputs": [{"path": source, "sha256": "b" * 64} for source in feature["inputs"]],
                         "targets": [{**target, "resolved": {"href": target["path"], "sha256": "c" * 64}}
                                     for target in feature["targets"]]})
    return {"schemaVersion": MANIFEST_SCHEMA, "revision": "a" * 40,
            "planSha256": hashlib.sha256(canonical_json(normalized)).hexdigest(), "features": features}


def catalog_plan(catalog: dict) -> dict:
    """Build only synthetic artifact targets to test the independent scope lock."""
    features = []
    for source in catalog["features"]:
        feature = {key: source[key] for key in
                   ("id", "title", "implementation", "demonstration", "reason")}
        feature.update(trackingIssues=[50], inputs=["examples/synthetic.cj"], targets=[])
        for locale in ("zh-CN", "en"):
            for target in source["targets"]:
                feature["targets"].append({"id": target["id"] + "-" + locale,
                                          "kind": "artifact", "path": "synthetic.html",
                                          "locale": locale, "version": target["version"],
                                          "instructions": "Synthetic scope check only",
                                          "scenarios": [{"id": source["journey"] + "-" + transport + "-" + viewport,
                                                         "mode": "file" if transport == "offline" else "http"}
                                                        for transport in ("root", "subpath", "offline")
                                                        for viewport in ("desktop", "narrow", "mobile")]})
        features.append(feature)
    return {"schemaVersion": PLAN_SCHEMA, "features": features}


class BaselineTests(unittest.TestCase):
    def setUp(self):
        self.baseline = load_json(ROOT / "site/showcase-baseline.json")
        self.plan = catalog_plan(load_json(ROOT / "site/showcase-catalog.json"))

    def assert_scope_rejected(self, plan: dict, pattern: str) -> None:
        with self.assertRaisesRegex(ContractError, pattern):
            check_baseline(self.baseline, resolved_manifest(plan))

    def test_committed_scope_matches_catalog_without_claiming_execution(self):
        self.assertEqual(self.baseline["schemaVersion"], BASELINE_SCHEMA)
        self.assertEqual(self.baseline["executionEvidence"], "none; browser evidence is required separately")
        self.assertEqual({*self.baseline["locales"]}, {"en", "zh-CN"})
        self.assertEqual(sum(feature["demonstration"] == "available"
                             for feature in self.baseline["features"]), 16)
        self.assertEqual(sum(feature["demonstration"] == "uncovered"
                             for feature in self.baseline["features"]), 1)
        versions = next(feature for feature in self.baseline["features"] if feature["id"] == "multi-version")
        self.assertEqual({(target["id"], target["version"]) for target in versions["targets"]},
                         {("common-overload", "demo-v2"), ("removed-member", "demo-v1"),
                          ("old-integer-overload", "demo-v1")})
        self.assertEqual(sum(len(target["scenarios"]) for feature in self.plan["features"]
                             for target in feature["targets"]), 324)
        check_baseline(self.baseline, resolved_manifest(self.plan))

    def test_missing_and_added_features_need_scope_review(self):
        for change in ("remove", "add"):
            plan = copy.deepcopy(self.plan)
            if change == "remove":
                plan["features"].pop(0)
            else:
                extra = copy.deepcopy(plan["features"][0])
                extra["id"] = "unreviewed-claim"
                plan["features"].append(extra)
            with self.subTest(change=change):
                self.assert_scope_rejected(plan, "feature scope changed")

    def test_uncovered_capability_cannot_disappear(self):
        self.plan["features"].pop()
        self.assert_scope_rejected(self.plan, "feature scope changed")

    def test_downgrade_and_unsupported_upgrade_need_scope_review(self):
        for field, value in (("demonstration", "blocked"), ("demonstration", "uncovered"),
                             ("implementation", "partial")):
            plan = copy.deepcopy(self.plan)
            plan["features"][0].update({field: value, "reason": "Synthetic scope change", "targets": []})
            # Keep a complete feature's valid targets for implementation-only changes.
            if field == "implementation":
                plan["features"][0]["targets"] = self.plan["features"][0]["targets"]
            with self.subTest(field=field, value=value):
                self.assert_scope_rejected(plan, field + " changed")
        plan = copy.deepcopy(self.plan)
        plan["features"][1]["implementation"] = "complete"
        self.assert_scope_rejected(plan, "implementation changed")

    def test_target_locale_and_version_changes_are_not_hidden_by_same_feature(self):
        for field, value in (("id", "different-target-en"), ("locale", "fr"), ("version", "demo-v3")):
            plan = copy.deepcopy(self.plan)
            plan["features"][0]["targets"][0][field] = value
            with self.subTest(field=field):
                self.assert_scope_rejected(plan, "target/locale/version scope changed")
        plan = copy.deepcopy(self.plan)
        plan["features"][0]["targets"].pop()
        self.assert_scope_rejected(plan, "target/locale/version scope changed")

    def test_mobile_file_and_subpath_cases_cannot_be_removed(self):
        for token in ("mobile", "offline", "subpath"):
            plan = copy.deepcopy(self.plan)
            target = plan["features"][0]["targets"][0]
            target["scenarios"] = [case for case in target["scenarios"] if token not in case["id"]]
            with self.subTest(token=token):
                self.assert_scope_rejected(plan, "scenario scope changed")

    def test_case_mode_and_journey_substitution_are_rejected(self):
        for field, value in (("mode", "file"), ("id", "search-root-desktop")):
            plan = copy.deepcopy(self.plan)
            plan["features"][0]["targets"][0]["scenarios"][0][field] = value
            with self.subTest(field=field):
                self.assert_scope_rejected(plan, "scenario scope changed")

    def test_unknown_fields_schema_and_execution_claim_are_rejected(self):
        for key, value in (("unexpected", True), ("schemaVersion", "cjdoc.showcase-baseline/2"),
                           ("executionEvidence", "all passed"), ("issue", True)):
            baseline = copy.deepcopy(self.baseline)
            baseline[key] = value
            with self.subTest(key=key), self.assertRaises(ContractError):
                validate_baseline(baseline)

    def test_duplicate_scope_entries_are_rejected(self):
        for field in ("features", "locales", "transports", "viewports"):
            baseline = copy.deepcopy(self.baseline)
            baseline[field].append(copy.deepcopy(baseline[field][0]))
            with self.subTest(field=field), self.assertRaisesRegex(ContractError, "duplicate"):
                validate_baseline(baseline)
        baseline = copy.deepcopy(self.baseline)
        baseline["features"][0]["targets"] *= 2
        with self.assertRaisesRegex(ContractError, "duplicate baseline target"):
            validate_baseline(baseline)

    def test_incomplete_matrix_is_rejected(self):
        for field in ("transports", "viewports"):
            baseline = copy.deepcopy(self.baseline)
            baseline[field].pop()
            with self.subTest(field=field), self.assertRaisesRegex(ContractError, "baseline requires"):
                validate_baseline(baseline)

    def test_baseline_and_manifest_are_not_mutated(self):
        baseline = copy.deepcopy(self.baseline)
        manifest = resolved_manifest(self.plan)
        before = json.dumps((baseline, manifest), sort_keys=True)
        check_baseline(baseline, manifest)
        self.assertEqual(json.dumps((baseline, manifest), sort_keys=True), before)

    def test_scope_does_not_fix_native_routes_or_source_revision(self):
        manifest = resolved_manifest(self.plan)
        manifest["revision"] = "d" * 40
        check_baseline(self.baseline, manifest)
        # Native target route changes are validated by resolution/browser evidence,
        # not compared to a copied SymbolId or stale path in this scope contract.
        self.plan["features"][0]["targets"][0]["path"] = "native-new-route.html"
        check_baseline(self.baseline, resolved_manifest(self.plan))


if __name__ == "__main__":
    unittest.main()
