"""Maintained source inputs shared by showcase generation and repository gates."""
from __future__ import annotations


def source_inputs() -> list[str]:
    """Return the maintained source inventory shared by gates and the manifest."""
    # Explicit, revision-controlled source inventory; derived indices are not source claims.
    inputs = ["site/showcase-catalog.json", "examples/pocketkit/LICENSE", "examples/pocketkit/README.md",
              "examples/pocketkit/reproduce.py", "scripts/publication_ir.py"]
    for version in ("demo-v1", "demo-v2"):
        inputs += [f"examples/pocketkit/{version}/{path}" for path in
                   ("cjpm.toml", "cjdoc.toml", "src/catalog.cj", "src/checks.cj", "src/io/reader.cj",
                    "src/io/checks.cj", "src/parsing/parser.cj", "src/parsing/checks.cj",
                    "docs/index.md", "docs/guide.md", "docs/en/guide.md")]
    inputs += [f"examples/pocketkit/demo-v2/{path}" for path in
               ("docs/reproduce.md", "docs/packages/pocketkit.md", "docs/doc-comments.md",
                "docs/en/doc-comments.md", "src/authoring/legacy.cj")]
    inputs += [f"examples/pocketkit/{part}/{path}" for part in ("support-v1", "diagnostics")
               for path in ("cjpm.toml", "cjdoc.toml", "src/api.cj", "docs/index.md")]
    inputs += [f"examples/pocketkit/check-modes/{path}" for path in
               ("cjpm.toml", "cjdoc.toml", "src/api.cj")]
    return inputs
