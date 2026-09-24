"""Exercise the archive CLI on synthetic files; not browser acceptance."""
from __future__ import annotations

import contextlib
import io
import unittest

import test_contract
from showcase_contract.__main__ import main
from showcase_contract.offline import ARCHIVE, extract_archive
from showcase_contract.site import Site


class ArchiveCliTests(unittest.TestCase):
    def setUp(self):
        self.fixture = f = test_contract.ContractTests()
        f.setUp()
        self.addCleanup(f.doCleanups)

    def test_archive_cli_produces_exact_extractable_payload(self):
        f = self.fixture
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main(["archive", "--site", str(f.site)]), 0)
        self.assertEqual(output.getvalue().strip(), str(f.site / ARCHIVE))
        extracted = extract_archive(f.site / ARCHIVE, f.root / "unpacked", Site(f.site))
        self.assertEqual(extracted.file("index.html").read_bytes(), (f.site / "index.html").read_bytes())

    def test_archive_cli_rejects_missing_site(self):
        with contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(main(["archive", "--site", str(self.fixture.root / "absent")]), 1)
        self.assertIn("showcase contract", errors.getvalue())
