#!/usr/bin/env python3
"""Generate, replay, query and inspect the captured admonition fixture."""
from __future__ import annotations

import argparse
from html.parser import HTMLParser
import json
from pathlib import Path
import subprocess

from test_query_mcp import McpProcess


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/fixtures/projects/admonitions"


class AdmonitionHtml(HTMLParser):
    def __init__(self, source: str):
        super().__init__(convert_charrefs=True)
        self.asides: list[dict[str, str]] = []
        self.image_count = 0
        self.text_parts: list[str] = []
        self.feed(source)

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = {key: value or "" for key, value in attrs}
        if tag == "aside" and "admonition" in attributes.get("class", "").split():
            self.asides.append(attributes)
        if tag == "img":
            self.image_count += 1

    def handle_data(self, value: str) -> None:
        self.text_parts.append(value)


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def run(binary: Path, *arguments: object) -> str:
    result = subprocess.run(
        [str(binary), *map(str, arguments)], text=True,
        capture_output=True, check=False, timeout=180,
    )
    assert result.returncode == 0, f"{arguments[0]} failed ({result.returncode}): {result.stderr}"
    return result.stdout


def query_cli(binary: Path, snapshot: Path, request: dict) -> dict:
    result = subprocess.run(
        [str(binary), "query", "--snapshot", str(snapshot), "--request", "-"],
        input=json.dumps(request, ensure_ascii=False) + "\n", text=True,
        capture_output=True, check=False, timeout=120,
    )
    assert result.returncode == 0, f"query failed ({result.returncode}): {result.stderr}"
    value = json.loads(result.stdout)
    assert isinstance(value, dict), "query did not return one JSON object"
    return value


def search_entry(index: dict, *, name: str, kind: str) -> dict:
    matches = [entry for entry in index["entries"]
               if entry.get("name") == name and entry.get("kind") == kind]
    assert len(matches) == 1, f"expected exactly one {kind} search entry named {name}"
    return matches[0]


def artifact_from_index(site: Path, href: str) -> Path:
    route = href.split("#", 1)[0].split("?", 1)[0]
    target = (site / route).resolve()
    assert target.is_relative_to(site.resolve()), "search href escapes the HTML root"
    assert target.is_file(), "search href does not resolve to a generated artifact"
    return target


def admonition_tags(comment: dict) -> list[dict]:
    return [tag for tag in comment.get("tags", [])
            if tag.get("name") in {"note", "warning", "danger"}]


def validate_products(output: Path, locale: str) -> tuple[Path, dict, dict, Path]:
    site = output / locale
    snapshot = site / "docs.json"
    document = read_json(snapshot)
    assert document.get("schemaVersion") == "cjdoc.doc-ir/18"
    declaration = next(symbol for symbol in document["declarations"]
                       if symbol.get("name") == "commit")
    comment = declaration["documentation"]
    tags = admonition_tags(comment)
    assert [tag["name"] for tag in tags] == ["warning", "danger"]
    assert all(tag.get("entryId") for tag in tags), "captured tag IDs were lost"
    localized = [text for text in comment.get("localizedTexts", [])
                 if text.get("kind") in {"note", "warning", "danger"}]
    assert {text["kind"] for text in localized} >= {"warning", "danger"}

    html_root = site / "html"
    index = read_json(html_root / "search-index.json")
    member = search_entry(index, name="commit", kind="function")
    assert member["body"].count("AdmonitionSearchSentinel") == 1
    assert member["bodyTruncated"] is False
    assert index["coverage"]["bodyComplete"] is True
    owner = next(entry for entry in index["entries"]
                 if entry.get("canonicalId") == member.get("ownerId"))
    owner_html = artifact_from_index(html_root, owner["href"]).read_text(encoding="utf-8")
    assert owner_html.count("admonition-risk-danger") == 1
    assert owner_html.count("admonition-risk-warning") == 1
    assert owner_html.index("admonition-risk-danger") < owner_html.index("admonition-risk-warning")
    member_html = artifact_from_index(html_root, member["href"]).read_text(encoding="utf-8")
    member_asides = AdmonitionHtml(member_html).asides
    # Owner context can contribute additional admonitions without replacing the member's tags.
    assert {"warning", "danger"} <= {aside.get("data-admonition-level") for aside in member_asides}
    expected = {"note": "Note", "warning": "Warning", "danger": "Danger"} if locale == "en" else {
        "note": "注意", "warning": "警告", "danger": "危险"}
    for aside in member_asides:
        level = aside["data-admonition-level"]
        assert aside.get("aria-label") == expected[level]
    owner_notes = [aside for aside in AdmonitionHtml(owner_html).asides
                   if aside.get("data-admonition-level") == "note"]
    assert len(owner_notes) == 1 and owner_notes[0].get("aria-label") == (
        "Note" if locale == "en" else "注意")
    assert 'role="alert"' not in member_html
    assert all("aria-live" not in aside for aside in member_asides)

    guide_html_path = html_root / "concepts/guides/admonitions.html"
    guide_html = guide_html_path.read_text(encoding="utf-8")
    parser = AdmonitionHtml(guide_html)
    assert [aside.get("data-admonition-level") for aside in parser.asides] == [
        "note", "warning", "danger", "warning"
    ]
    for aside in parser.asides:
        assert "role" not in aside and "aria-live" not in aside
    assert parser.image_count == 0
    for marker in ("[!DANGER]", "[!TIP]", "[!NOTE] Inline marker text", "[!WARNING] Nested alert-like text"):
        assert marker in " ".join(" ".join(parser.text_parts).split())
    assert "&lt;img src=x onerror=alert(1)&gt;" in guide_html
    assert "<img src=x onerror=alert(1)>" not in guide_html

    markdown_files = list((site / "markdown").rglob("*.md"))
    guide_markdown = next(path.read_text(encoding="utf-8") for path in markdown_files
                          if "Cache contents are hints, not sources of truth" in path.read_text(encoding="utf-8"))
    assert "> [!NOTE]\n> \n> Cache contents are hints, not sources of truth" in guide_markdown
    assert "> [!WARNING]" in guide_markdown and "> [!CAUTION]" in guide_markdown

    agent_root = html_root / "agent"
    declarations = []
    pages = []
    for path in agent_root.rglob("*.json"):
        try:
            value = read_json(path)
        except (OSError, json.JSONDecodeError):
            continue
        if value.get("schemaVersion") == "cjdoc.declaration/3":
            symbol = value.get("symbol", {})
            if symbol.get("name") == "commit":
                declarations.append(value)
        if value.get("schemaVersion") == "cjdoc.page/2" and value.get("id") == "admonition-guide":
            pages.append((path, value))
    assert len(declarations) == 1, "Agent declaration/3 output is missing"
    assert {tag.get("name") for tag in admonition_tags(declarations[0]["symbol"]["documentation"])} == {
        "warning", "danger"
    }
    assert len(pages) == 1, "Agent page/2 output is missing"
    page_path, page = pages[0]
    assert "[!NOTE]" in page["markdown"] and "[!CAUTION]" in page["markdown"]

    return snapshot, index, member, page_path.relative_to(site)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    binary, output = args.binary.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    for name in ("en", "zh-CN", "replay-en", "replay-zh-CN"):
        assert not (output / name).exists(), f"output child already exists: {name}"

    products = {}
    for locale in ("en", "zh-CN"):
        site = output / locale
        run(binary, "generate", "--project", FIXTURE, "--format", "json", "--format", "html",
            "--format", "markdown", "--agent-full", "--locale", locale, "--output", site,
            "--no-cache")
        products[locale] = validate_products(output, locale)

        replay = output / f"replay-{locale}"
        run(binary, "render", "--input", products[locale][0], "--format", "json", "--format", "html",
            "--format", "markdown", "--agent-full", "--locale", locale, "--output", replay)
        for relative in (
            Path("docs.json"), Path("html/search-index.json"),
            Path("html/concepts/guides/admonitions.html"), products[locale][3],
        ):
            original = (site / relative).read_bytes()
            regenerated = (replay / relative).read_bytes()
            assert original == regenerated, f"generate/replay mismatch: {locale}/{relative}"

    snapshot, _, _, _ = products["en"]
    symbol_id = next(symbol["id"] for symbol in read_json(snapshot)["declarations"]
                     if symbol.get("name") == "commit")
    request = {
        "operation": "get_symbol", "symbolId": symbol_id, "sections": ["description"],
        "language": "en", "maxBytes": 65536,
    }
    cli_result = query_cli(binary, snapshot, request)
    assert cli_result.get("schemaVersion") == "cjdoc.query-result/4"
    assert cli_result.get("status") == "ok"
    item = cli_result["result"]["items"][0]
    description = next(section for section in item["sections"]
                       if section["name"] == "description")
    assert description["state"] == "available"
    tags = description["value"]["documentationTags"]
    assert {tag["name"] for tag in tags} == {"warning", "danger"}
    assert {text["kind"] for text in description["value"]["localizedTexts"]} >= {
        "warning", "danger"
    }

    search = query_cli(binary, snapshot, {
        "operation": "search", "query": "AdmonitionSearchSentinel", "profile": "full-ir",
        "language": "en", "limit": 10,
    })
    assert search.get("status") == "ok"
    matches = search["result"]["items"]
    assert len(matches) == 1 and matches[0]["identity"]["symbolId"] == symbol_id

    mcp = McpProcess(binary, (snapshot,))
    try:
        mcp.initialize()
        mcp.mark_initialized()
        result = mcp.result("tools/call", {
            "name": "get_symbol",
            "arguments": {key: value for key, value in request.items() if key != "operation"},
        })
        assert result["structuredContent"] == cli_result, "CLI and MCP structured query results differ"
    finally:
        assert mcp.close() == 0, "MCP consumer did not exit cleanly"

    print("PASS: admonition capture, HTML/Markdown, Agent, full-IR query/search and MCP replay")


if __name__ == "__main__":
    main()
