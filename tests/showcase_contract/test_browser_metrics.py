"""Synthetic negative tests for measured-evidence gates, not browser evidence."""
from __future__ import annotations

import copy
import unittest

import test_contract
from showcase_contract.browser import registered_cases
from showcase_contract.browser_metrics import validate_metrics
from showcase_contract.evidence import validate_evidence
from showcase_contract.scenarios import SCENARIOS, JOURNEYS
from showcase_contract.site import ContractError, Site


class MetricsTests(unittest.TestCase):
    def setUp(self):
        self.metrics = {"viewport": {"width": 960, "height": 900},
                        "landing": {"memberCount": 26, "firstScreenMembers": 4,
                                    "listHeight": 4000, "compactRowHeight": 90,
                                    "contentTop": 130, "horizontalOverflow": False, "scrollY": 300},
                        "scrollEvents": 8, "scrollDistance": 3100,
                        "queryMs": [20.1], "expandMs": [30.2],
                        "homepageActivations": 1, "homepageDocumentNavigations": 1}
        self.scenario = SCENARIOS["members-root-narrow"]

    def test_registry_has_complete_matrix_for_all_catalog_journeys(self):
        for journey in JOURNEYS:
            for transport in ("root", "subpath", "offline"):
                for width in ("desktop", "narrow", "mobile"):
                    scenario = SCENARIOS[f"{journey}-{transport}-{width}"]
                    self.assertEqual(scenario[0], journey)
                    self.assertEqual(scenario[1], "file" if transport == "offline" else "http")
        self.assertEqual(self.scenario[2], 960)

    def test_controlled_observed_metrics_pass(self):
        validate_metrics(self.metrics, self.scenario)

    def test_empty_timing_cannot_claim_interaction_measured(self):
        for key in ("queryMs", "expandMs"):
            broken = copy.deepcopy(self.metrics)
            broken[key] = []
            with self.assertRaisesRegex(ContractError, "not measured"):
                validate_metrics(broken, self.scenario)

    def test_missing_layout_and_fake_viewport_fail(self):
        for key in ("landing", "viewport", "scrollEvents"):
            broken = copy.deepcopy(self.metrics)
            del broken[key]
            with self.assertRaises(ContractError):
                validate_metrics(broken, self.scenario)
        self.metrics["viewport"]["width"] = 1440
        with self.assertRaisesRegex(ContractError, "viewport"):
            validate_metrics(self.metrics, self.scenario)

    def test_over_budget_nonfinite_and_negative_timings_fail(self):
        for value in (-1, 1600, float("nan"), float("inf"), True, "12"):
            broken = copy.deepcopy(self.metrics)
            broken["queryMs"] = [value]
            with self.subTest(value=value), self.assertRaises(ContractError):
                validate_metrics(broken, self.scenario)

    def test_extra_navigation_cannot_pass_one_activation_claim(self):
        for key in ("homepageActivations", "homepageDocumentNavigations"):
            broken = copy.deepcopy(self.metrics)
            broken[key] = 2
            with self.assertRaisesRegex(ContractError, "navigation budget"):
                validate_metrics(broken, self.scenario)

    def test_split_blank_space_overflow_and_empty_landing_fail(self):
        for key, value in (("contentTop", 950), ("horizontalOverflow", True),
                           ("firstScreenMembers", 0), ("memberCount", 19),
                           ("listHeight", 17000), ("compactRowHeight", 300)):
            broken = copy.deepcopy(self.metrics)
            broken["landing"][key] = value
            with self.subTest(key=key), self.assertRaises(ContractError):
                validate_metrics(broken, self.scenario)

    def test_modern_scenarios_reject_legacy_unmeasured_evidence(self):
        fixture = test_contract.ContractTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        fixture.target["scenarios"] = [{"id": "search-root-desktop", "mode": "http"}]
        manifest = fixture.resolve()
        evidence = fixture.evidence(manifest)
        with self.assertRaisesRegex(ContractError, "measured.*v2"):
            validate_evidence(manifest, evidence, Site(fixture.site), fixture.evidence_root)


class ThemeEvidenceTests(unittest.TestCase):
    def test_showcase_screenshots_select_each_explicit_theme_option(self):
        """The screenshot gate must not assume the picker itself toggles light/dark."""
        import sys
        import tempfile
        from pathlib import Path
        from types import ModuleType, SimpleNamespace
        from unittest.mock import patch
        from showcase_contract.browser_metrics import screenshots

        class Locator:
            def __init__(self, page, selector):
                self.page = page
                self.selector = selector

            def count(self):
                return 0 if self.selector == "[data-cjdoc-theme-toggle]" else 1

            def get_attribute(self, key):
                if self.selector == "html" and key == "data-theme":
                    return self.page.theme
                raise AssertionError(f"Unexpected attribute: {self.selector} {key}")

        class Page:
            def __init__(self):
                self.theme = "paper"
                self.activated = []

            def locator(self, selector):
                return Locator(self, selector)

            def evaluate(self, code):
                self.activated.append(("evaluate", code))
                return False

            def screenshot(self, *, path, full_page):
                self.activated.append(("screenshot", self.theme))
                Path(path).write_bytes(b"synthetic unit-test screenshot")

        class Journey:
            def __init__(self):
                self.page = Page()
                self.assertions = []
                self.picker_open = False

            def click(self, locator):
                if locator.selector == "[data-showcase-theme]":
                    self.picker_open = True
                    self.page.activated.append(("open",))
                elif locator.selector.startswith('[data-showcase-theme-value="'):
                    if not self.picker_open:
                        raise AssertionError("Theme option was clicked without opening the picker")
                    self.page.theme = locator.selector.split('"')[1]
                    self.picker_open = False
                    self.page.activated.append(("select", self.page.theme))
                else:
                    raise AssertionError(f"Unexpected click: {locator.selector}")

        class Expectation:
            def __init__(self, locator):
                self.locator = locator

            def to_have_count(self, count):
                assert self.locator.count() == count

            def to_have_attribute(self, key, value):
                assert self.locator.get_attribute(key) == value

        package = ModuleType("playwright")
        library = ModuleType("playwright.sync_api")
        library.expect = lambda locator: Expectation(locator)
        journey = Journey()
        with tempfile.TemporaryDirectory() as temp, patch.dict(
            sys.modules, {"playwright": package, "playwright.sync_api": library}
        ):
            images = screenshots(journey, ("showcase", "root", "desktop"), Path(temp))
            self.assertEqual([image["theme"] for image in images], ["light", "dark"])
            self.assertEqual([event for event in journey.page.activated
                              if event[0] in {"open", "select", "screenshot"}], [
                ("open",), ("select", "light"), ("screenshot", "light"),
                ("open",), ("select", "dark"), ("screenshot", "dark"),
            ])

    def test_theme_attachment_cannot_be_text_or_reused(self):
        import hashlib
        import tempfile
        from pathlib import Path
        from showcase_contract.evidence import validate_theme_images
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = b'synthetic attachment, not browser evidence'
            for name in ('light.png', 'dark.png'):
                (root / name).write_bytes(payload)
            pictures = [{"theme": theme, "path": theme + '.png',
                         "sha256": hashlib.sha256(payload).hexdigest()} for theme in ('light', 'dark')]
            with self.assertRaisesRegex(ContractError, "not a PNG"):
                validate_theme_images(pictures, Site(root))
            pictures[1]['path'] = 'light.png'
            with self.assertRaisesRegex(ContractError, "distinct"):
                validate_theme_images(pictures, Site(root))

    def test_light_and_dark_are_both_mandatory(self):
        import tempfile
        from pathlib import Path
        from showcase_contract.evidence import validate_theme_images
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ContractError, "both"):
                validate_theme_images([{"theme": "light"}], Site(Path(temporary)))


if __name__ == "__main__":
    unittest.main()
