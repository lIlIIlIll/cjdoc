"""Runner control-flow tests, explicitly not real-browser behavioral evidence."""
from __future__ import annotations

import json
import unittest

import test_contract
from showcase_contract import ContractError
from showcase_contract.browser import registered_cases, run, same_route, screenshot_name


class BrowserContractTests(unittest.TestCase):
    def setUp(self):
        self.fixture = f = test_contract.ContractTests()
        f.setUp()
        self.addCleanup(f.doCleanups)

    def test_unknown_scenario_fails_not_skips(self):
        with self.assertRaisesRegex(ContractError, "unimplemented"):
            registered_cases(self.fixture.resolve())

    def test_supported_search_uses_manifest_targets(self):
        self.fixture.target["scenarios"] = [{"id": "search-root", "mode": "http"}]
        cases = registered_cases(self.fixture.resolve())
        self.assertEqual(len(cases), 1)
        self.assertEqual(next(iter(cases.values()))["resolved"]["href"], self.fixture.page_name + "#add")

    def test_protocol_mismatch_fails(self):
        self.fixture.target["scenarios"] = [{"id": "search-root", "mode": "file"}]
        with self.assertRaisesRegex(ContractError, "mismatched"):
            registered_cases(self.fixture.resolve())

    def test_member_scenario_requires_real_member_placement(self):
        self.fixture.target["scenarios"] = [{"id": "member-offline", "mode": "file"}]
        with self.assertRaisesRegex(ContractError, "inline member"):
            registered_cases(self.fixture.resolve())

    def test_zero_available_features_cannot_pass(self):
        self.fixture.feature["demonstration"] = "uncovered"
        with self.assertRaisesRegex(ContractError, "vacuous"):
            registered_cases(self.fixture.resolve())

    def test_exact_url_includes_host_path_query_and_fragment(self):
        self.assertTrue(same_route('http://127.0.0.1:123/p/x.html#%E4%B8%AD',
                                   'http://127.0.0.1:123/p/', 'x.html#中'))
        for actual in ['http://127.0.0.1:123/p/x.html#other', 'http://other/p/x.html#中',
                       'http://127.0.0.1:123/p/x.html?unexpected=1#中',
                       'http://127.0.0.1:123/other/x.html#中']:
            self.assertFalse(same_route(actual, 'http://127.0.0.1:123/p/', 'x.html#中'))

    def test_existing_evidence_is_not_reused_or_overwritten(self):
        evidence = self.fixture.evidence_root
        marker = evidence / "results.json"
        marker.write_text('old')
        with self.assertRaisesRegex(ContractError, "new directory"):
            run(self.fixture.site, evidence)
        self.assertEqual(marker.read_text(), 'old')

    def test_output_in_published_tree_is_rejected(self):
        with self.assertRaisesRegex(ContractError, "separate"):
            run(self.fixture.site, self.fixture.site / "evidence")

    def test_missing_manifest_leaves_failure_not_success(self):
        evidence = self.fixture.root / "fresh-evidence"
        with self.assertRaises(ContractError):
            run(self.fixture.site, evidence)
        self.assertFalse((evidence / 'results.json').exists())
        failure = json.loads((evidence / 'failures.json').read_text())
        self.assertEqual(failure['status'], 'failed')

    def test_unknown_scenario_writes_failure_not_success(self):
        f = self.fixture
        test_contract.write(f.site, 'showcase-features.json', f.resolve())
        evidence = f.root / "fresh-evidence"
        with self.assertRaisesRegex(ContractError, "unimplemented"):
            run(f.site, evidence)
        self.assertFalse((evidence / 'results.json').exists())
        self.assertTrue((evidence / 'failures.json').exists())

    def test_screenshot_names_cannot_collide_through_id_delimiters(self):
        self.assertNotEqual(screenshot_name(("a-b", "c", "search-root", "http", "en", "v2")),
                            screenshot_name(("a", "b-c", "search-root", "http", "en", "v2")))

    def test_screenshot_names_include_version_and_locale(self):
        key = ("f", "t", "search-root", "http", "en", "v2")
        self.assertEqual(screenshot_name(key), screenshot_name(key))
        self.assertNotEqual(screenshot_name(key), screenshot_name((*key[:4], "zh", "v2")))
        self.assertNotEqual(screenshot_name(key), screenshot_name((*key[:5], "v1")))
