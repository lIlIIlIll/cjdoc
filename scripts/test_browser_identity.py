"""Browser stages must publish the identity the paired-sample report compares.

DONE-03 pairs samples under a matched browser and font set. Two stages really drive a
browser -- the Linux acceptance matrix and the Pages browser shards -- and until they
reported what they launched, every cell could only say "met on the recorded axes
only". These tests pin the reporting itself and the property that made it necessary:
both stages must produce the SAME shape, or their conditions never intersect and the
evidence silently stops pairing.
"""

from __future__ import annotations

import importlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import ci_stage


class ReportedBrowserIdentityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_the_matrix_has_no_private_font_digest(self) -> None:
        """The digest must have exactly ONE implementation.

        Two call sites hashing the same fonts independently would produce conditions
        that can never be equal, and every cell would silently stay unpaired while the
        report still looked complete. The matrix therefore calls the shared helper.
        """
        matrix = importlib.import_module("accept_package_index_matrix")
        self.assertFalse(hasattr(matrix, "_font_set_digest"))
        self.assertIs(matrix.ci_stage, ci_stage)
        source = (SCRIPTS / "accept_package_index_matrix.py").read_text(encoding="utf-8")
        self.assertIn("ci_stage.font_set_digest()", source)
        # It reports AFTER the matrix ran, so a version is only ever published for a
        # run that actually launched a browser.
        self.assertLess(source.index("browser_version = browser.version"),
                        source.index("ci_stage.report_identity("))

    def test_both_browser_stages_report_the_same_field_shape(self) -> None:
        """Two stages with different shapes would never pair their signatures.

        The condition is built from the identity tuple, so a stage that reported only
        `browserVersion` would produce a signature that cannot equal one from a stage
        that also reported the font set -- and `report` would silently pool nothing.
        """
        from showcase_contract import browser as showcase_browser

        captured: dict[str, str] = {}

        def record(values, path=None):  # noqa: ANN001 - mirrors the real signature
            captured.update(values)
            return None

        with mock.patch.object(ci_stage, "report_identity", side_effect=record):
            showcase_browser._report_browser_identity("152.0")
        self.assertEqual(captured["browserVersion"], "152.0")
        self.assertEqual(captured["browserIdentity"], "chromium")
        self.assertIn("fontSetDigest", captured)

    def test_reporting_is_a_no_op_without_a_recorder(self) -> None:
        """Running a stage by hand must not write a file nothing will read.

        The report path defaults to the recorder's environment, so a regression that
        wrote somewhere else -- the working directory, say -- would otherwise go
        unnoticed: the assertion has to look where such a write would land.
        """
        previous = os.getcwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, previous)
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop(ci_stage.IDENTITY_REPORT_ENV, None)
            ci_stage.report_identity({"browserVersion": "152.0"})
        self.assertEqual(list(self.root.iterdir()), [])

    def test_a_stage_writes_only_the_declared_fields(self) -> None:
        """The channel is an allow-list, so an extra key must not reach the record."""
        target = self.root / "evidence" / "stage-identity.json"
        ci_stage.report_identity({"browserVersion": "152.0", "sdkVersion": "spoofed"},
                                 target)
        payload = json.loads(target.read_text(encoding="utf-8"))
        self.assertEqual(sorted(payload), sorted(ci_stage.REPORTABLE_IDENTITY))
        self.assertEqual(payload["browserVersion"], "152.0")
        # Undeclared fields are dropped on the way out, never written: `sdkVersion` is
        # the recorder's own value and a stage that tried to set it must have no effect.
        self.assertNotIn("sdkVersion", payload)

    def test_the_font_digest_is_stable_and_shared(self) -> None:
        """One implementation: two digests for the same fonts would never pair."""
        first = ci_stage.font_set_digest()
        self.assertEqual(first, ci_stage.font_set_digest())
        # Either the machine can resolve fonts, or it honestly reports none.
        self.assertTrue(first == "" or len(first) == 64, first)

    def test_the_font_digest_tracks_version_metadata(self) -> None:
        """Same-family font updates must not retain the same matched identity."""
        listed_versions = [
            mock.Mock(stdout="Fixture Sans\t202602\n"),
            mock.Mock(stdout="Fixture Sans\t202602\n"),
            mock.Mock(stdout="Fixture Sans\t202603\n"),
        ]
        with mock.patch.object(ci_stage.subprocess, "run", side_effect=listed_versions):
            first = ci_stage.font_set_digest()
            same_version = ci_stage.font_set_digest()
            changed_version = ci_stage.font_set_digest()
        self.assertEqual(first, same_version)
        self.assertNotEqual(first, changed_version)


if __name__ == "__main__":
    unittest.main()
