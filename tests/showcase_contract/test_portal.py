"""Synthetic projection regressions; not native build or browser evidence."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from showcase_build.portal import preview, render_version, summary, version_target
from showcase_contract.site import ContractError


class PortalTests(unittest.TestCase):
    def fixture(self):
        return {"features": [
            {"id": "multi-version", "targets": [{"id": "old-integer-overload-en",
             "locale": "en", "version": "demo-v1", "resolved": {"href": "old.html"}}]},
            {"id": "compact-members", "targets": [{"id": "append-string-en",
             "locale": "en", "version": "demo-v2", "resolved": {"href": "new.html"}}]},
        ]}

    def test_version_selection_is_locale_scoped(self):
        manifest = self.fixture()
        self.assertEqual(version_target(manifest, "en", "demo-v1")["resolved"]["href"], "old.html")
        self.assertEqual(version_target(manifest, "en", "demo-v2")["resolved"]["href"], "new.html")
        with self.assertRaises(ContractError):
            version_target(manifest, "zh-CN", "demo-v1")

    def test_localized_summary_never_mislabels_other_language(self):
        declaration = {"documentation": {"summary": "中文", "defaultLanguage": "zh-CN",
                       "localizedTexts": [{"kind": "summary", "language": "en", "text": "English"}]}}
        self.assertEqual(summary(declaration, "zh-CN"), "中文")
        self.assertEqual(summary(declaration, "en"), "English")
        self.assertEqual(summary(declaration, "other"), "")

    def test_preview_escapes_native_content_and_retains_real_links(self):
        owner = {"name": "TextCatalog", "packageName": "pocketkit", "kind": "class"}
        member = {"headerSpelling": "public func add(value: Array<String>): Unit",
                  "documentation": {"summary": '<script>alert(1)</script>', "defaultLanguage": "en"}}
        with patch("showcase_build.portal.version_data",
                   return_value=(owner, [(member, "native/member.html")], "native/owner.html")):
            html = render_version(None, {"version": "demo-v2"}, "en")
        self.assertIn('href="native/member.html"', html)
        self.assertIn('href="native/owner.html"', html)
        self.assertIn("Array&lt;String&gt;", html)
        self.assertIn("&lt;script&gt;", html)
        self.assertNotIn("<script>", html)

    def test_both_versions_readable_without_javascript(self):
        owner = {"name": "TextCatalog", "packageName": "pocketkit", "kind": "class"}
        with patch("showcase_build.portal.version_data", return_value=(owner, [], "native.html")):
            html = preview(None, self.fixture(), "en")
        self.assertIn('data-portal-version="demo-v2" aria-label=', html)
        self.assertIn('data-portal-version="demo-v1" aria-label=', html)
        self.assertIn('data-portal-controls hidden', html)


if __name__ == "__main__":
    unittest.main()
