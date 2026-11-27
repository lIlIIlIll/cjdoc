"""Keep the current-only upgrade instructions aligned with the Doc IR wire."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[1]


class ReleaseNotesTest(unittest.TestCase):
    def test_current_upgrade_instructions_match_the_supported_doc_ir(self) -> None:
        primitives = (REPO / "src/model/doc_ir_primitives.cj").read_text(encoding="utf-8")
        versions = re.findall(r'DOC_IR_SCHEMA_VERSION\s*=\s*"cjdoc\.doc-ir/(\d+)"', primitives)
        self.assertEqual(len(versions), 1, "expected one Doc IR contract version")
        version = int(versions[0])
        notes = (REPO / "docs/release-notes.md").read_text(encoding="utf-8")
        heading = "## 当前源码（尚未发布）\n"
        self.assertIn(heading, notes)
        current = notes.split(heading, 1)[1].split("\n## ", 1)[0]
        self.assertEqual(re.findall(r"Doc IR v(\d+)", current), [str(version)])
        self.assertIn(f"`render` 不读取 v{version - 1} 及更早版本", current)
        artifacts = (REPO / "docs/reference/artifacts.md").read_text(encoding="utf-8")
        self.assertIn(f"`cjdoc.doc-ir/{version}` 是当前 Doc IR wire", artifacts)
        self.assertIn(f"都不接受 `/{version - 1}` 及更早版本", artifacts)
