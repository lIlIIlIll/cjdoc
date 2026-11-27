"""Do not let header-only native test files silently enter the suite."""
from pathlib import Path
import re
import unittest


REPO = Path(__file__).resolve().parents[1]
HEADER = re.compile(r"\s*(?:package\s+[\w.]+\s*)?\Z")
COMMENTS = re.compile(r"//[^\n]*|/\*.*?\*/", re.DOTALL)


class NativeTestSourcesTest(unittest.TestCase):
    def test_source_tree_has_no_header_only_test_modules(self) -> None:
        empty = []
        for path in sorted((REPO / "src").rglob("*_test.cj")):
            source = path.read_text(encoding="utf-8")
            # Fixture-helper modules are valid even without an @Test; only
            # modules containing no code beyond the package header are empty.
            if HEADER.fullmatch(COMMENTS.sub("", source)):
                empty.append(path.relative_to(REPO).as_posix())
        self.assertEqual(empty, [], "remove header-only native test modules")
