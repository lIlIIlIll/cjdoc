"""Platform portability for comparisons of actual browser clipboard contents."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from showcase_contract.browser_support import clipboard_code_matches


class ClipboardCodeTests(unittest.TestCase):
    def test_crlf_conversion_and_existing_outer_whitespace_tolerance(self) -> None:
        source = 'let text = "中文"\nassert(text.size > 0)'
        self.assertTrue(clipboard_code_matches("\r\n" + source.replace("\n", "\r\n") + "\r\n", source))
        self.assertTrue(clipboard_code_matches(source, source.replace("\n", "\r\n")))

    def test_changed_code_and_interior_whitespace_are_rejected(self) -> None:
        source = 'let text = "hello"\nassert(text.size > 0)'
        self.assertFalse(clipboard_code_matches(source.replace("hello", "world"), source))
        self.assertFalse(clipboard_code_matches(source.replace("\n", "\r\n "), source))

    def test_lone_carriage_return_is_not_removed_or_reinterpreted(self) -> None:
        self.assertFalse(clipboard_code_matches("first\rsecond", "first\nsecond"))
        self.assertFalse(clipboard_code_matches("first\rsecond", "firstsecond"))
        self.assertTrue(clipboard_code_matches("first\rsecond", "first\rsecond"))


if __name__ == "__main__":
    unittest.main()
