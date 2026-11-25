"""Protect existing output trees before the browser acceptance starts."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from accept_package_index_matrix import prepare_matrix_output


MATRIX = Path(__file__).with_name("accept_package_index_matrix.py")


class MatrixOutputTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.output = self.root / "real" / "matrix"
        (self.output / "work").mkdir(parents=True)
        self.sentinel = self.output / "work" / "sentinel.txt"
        self.sentinel.write_bytes(b"owned previous run")
        self.marker = self.output / "package-index-matrix.owner"

    def cli(self, output, *, isolate_site):
        flags = ["-B", "-I", "-S"] if isolate_site else ["-B"]
        return subprocess.run([sys.executable, *flags, MATRIX, "--binary", self.root / "unused",
                               "--output", output], capture_output=True, text=True, timeout=20)

    def test_direct_and_ancestor_links_leave_existing_work_untouched(self):
        self.marker.write_bytes(b"cjdoc package index matrix\n")
        direct = self.root / "direct"
        ancestor = self.root / "ancestor"
        try:
            direct.symlink_to(self.output, target_is_directory=True)
            ancestor.symlink_to(self.output.parent, target_is_directory=True)
        except (OSError, NotImplementedError) as error:
            self.skipTest(f"directory symlinks unavailable: {error}")
        for output in (direct, ancestor / "matrix", ancestor / ".." / "real" / "matrix"):
            for isolate_site in (False, True):
                with self.subTest(output=output.name, isolate_site=isolate_site):
                    result = self.cli(output, isolate_site=isolate_site)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertRegex(result.stderr, r"symlink|parent segments")
                    self.assertEqual(self.sentinel.read_bytes(), b"owned previous run")
                    self.assertEqual(self.marker.read_bytes(), b"cjdoc package index matrix\n")

    def test_owned_work_is_replaced_and_unmarked_work_is_preserved(self):
        with self.assertRaisesRegex(ValueError, "not owned"):
            prepare_matrix_output(self.output)
        self.assertEqual(self.sentinel.read_bytes(), b"owned previous run")
        self.assertFalse(self.marker.exists())
        self.marker.write_bytes(b"cjdoc package index matrix\n")
        adjacent = self.output / "keep.txt"
        adjacent.write_bytes(b"not part of the scratch tree")
        output, work = prepare_matrix_output(self.output)
        self.assertEqual(output, self.output)
        self.assertEqual(list(work.iterdir()), [])
        self.assertEqual(adjacent.read_bytes(), b"not part of the scratch tree")
