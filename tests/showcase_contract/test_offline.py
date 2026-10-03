"""Offline payload tests; these do not substitute for file:// browser tests."""
from __future__ import annotations

import os
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

from showcase_contract.site import ContractError, Site
from showcase_contract.offline import ARCHIVE, create_archive, extract_archive, payload_digest


class OfflineTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.site = self.root / "site"
        self.site.mkdir()
        (self.site / "index.html").write_text('<html lang="en">Offline</html>')
        (self.site / "search-index.js").write_text('window.searchIndex=[];')
        self.destination = self.root / "unpacked"

    def test_round_trip_all_payload_bytes(self):
        archive = create_archive(self.site)
        before = Site(self.site)
        after = extract_archive(archive, self.destination, before)
        self.assertEqual(payload_digest(before), payload_digest(after))
        self.assertNotIn(ARCHIVE, after.files)

    def test_repeated_archives_are_byte_identical(self):
        first = create_archive(self.site).read_bytes()
        for path in self.site.iterdir():
            os.utime(path, (100, 100))
        self.assertEqual(first, create_archive(self.site).read_bytes())

    def test_other_downloads_are_included(self):
        (self.site / "downloads").mkdir()
        (self.site / "downloads/source.zip").write_bytes(b"source-download")
        archive = create_archive(self.site)
        result = extract_archive(archive, self.destination, Site(self.site))
        self.assertIn("downloads/source.zip", result.files)

    def test_stale_archive_fails(self):
        archive = create_archive(self.site)
        (self.site / "search-index.js").write_text("changed")
        with self.assertRaisesRegex(ContractError, "bytes differ"):
            extract_archive(archive, self.destination, Site(self.site))

    def test_missing_file_fails(self):
        archive = create_archive(self.site)
        (self.site / "new.js").write_text("new")
        with self.assertRaisesRegex(ContractError, "inventory"):
            extract_archive(archive, self.destination, Site(self.site))

    def test_extra_file_fails(self):
        archive = create_archive(self.site)
        with zipfile.ZipFile(archive, "a") as z:
            z.writestr("unreviewed.txt", "not a final-site file")
        with self.assertRaisesRegex(ContractError, "inventory"):
            extract_archive(archive, self.destination, Site(self.site))

    def test_traversal_fails_before_writes(self):
        archive = create_archive(self.site)
        with zipfile.ZipFile(archive, "a") as z:
            z.writestr("../escape", "bad")
        with self.assertRaisesRegex(ContractError, "noncanonical"):
            extract_archive(archive, self.destination, Site(self.site))
        self.assertFalse(self.destination.exists())
        self.assertFalse((self.root / "escape").exists())

    def test_absolute_archive_entry_fails(self):
        archive = create_archive(self.site)
        with zipfile.ZipFile(archive, "a") as z:
            z.writestr("/absolute", "bad")
        with self.assertRaisesRegex(ContractError, "unsafe artifact"):
            extract_archive(archive, self.destination, Site(self.site))

    def test_symlink_entry_fails(self):
        archive = create_archive(self.site)
        with zipfile.ZipFile(archive, "a") as z:
            i = zipfile.ZipInfo("link")
            i.create_system = 3
            i.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(i, "../elsewhere")
        with self.assertRaisesRegex(ContractError, "symlink"):
            extract_archive(archive, self.destination, Site(self.site))

    def test_case_collision_fails(self):
        archive = create_archive(self.site)
        with zipfile.ZipFile(archive, "a") as z:
            z.writestr("INDEX.html", "other")
        with self.assertRaisesRegex(ContractError, "case-colliding"):
            extract_archive(archive, self.destination, Site(self.site))

    def test_existing_extraction_directory_is_never_reused(self):
        archive = create_archive(self.site)
        self.destination.mkdir()
        with self.assertRaisesRegex(ContractError, "fresh directory"):
            extract_archive(archive, self.destination, Site(self.site))

    def test_in_site_extraction_is_rejected(self):
        archive = create_archive(self.site)
        with self.assertRaisesRegex(ContractError, "separate"):
            extract_archive(archive, self.site / "unpack", Site(self.site))

    def test_symlink_source_is_rejected(self):
        (self.site / "link").symlink_to(self.site / "index.html")
        with self.assertRaisesRegex(ContractError, "symlink"):
            create_archive(self.site)

    def test_truncated_zip_fails(self):
        archive = create_archive(self.site)
        archive.write_bytes(b"not a zip")
        with self.assertRaisesRegex(ContractError, "invalid offline archive"):
            extract_archive(archive, self.destination, Site(self.site))
