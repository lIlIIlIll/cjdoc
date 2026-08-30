#!/usr/bin/env python3
"""Validate every cjdoc HTML page, local link, search target, and script sink."""

from __future__ import annotations

import json
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.ids: set[str] = set()
        self.links: list[str] = []
        self.errors: list[str] = []
        self.script_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        lowered_tag = tag.lower()
        if lowered_tag in {"iframe", "object", "embed"}:
            self.errors.append(f"forbidden element <{tag}>")
        values = {name.lower(): value for name, value in attrs}
        if lowered_tag == "script":
            self.script_depth += 1
            if not values.get("src"):
                self.errors.append("inline script is forbidden")
        for name, value in attrs:
            if value is None:
                continue
            lowered = name.lower()
            if lowered == "id":
                if value in self.ids:
                    self.errors.append(f"duplicate id {value!r}")
                self.ids.add(value)
            elif lowered in {"href", "src"}:
                self.links.append(value)
            elif lowered.startswith("on"):
                self.errors.append(f"forbidden event attribute {name!r}")

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "script" and self.script_depth:
            self.script_depth -= 1

    def handle_data(self, data: str) -> None:
        if self.script_depth and data.strip():
            self.errors.append("inline script content is forbidden")


def resolve_local(root: Path, source: Path, value: str) -> tuple[Path | None, str]:
    parsed = urlsplit(value)
    if parsed.scheme:
        if parsed.scheme.lower() not in {"http", "https", "mailto"}:
            raise ValueError(f"unsafe URL scheme in {source.relative_to(root)}: {value}")
        return None, ""
    if parsed.netloc:
        raise ValueError(f"protocol-relative URL in {source.relative_to(root)}: {value}")
    if parsed.path.startswith("/"):
        raise ValueError(f"absolute local URL in {source.relative_to(root)}: {value}")
    target = (source.parent / parsed.path).resolve() if parsed.path else source.resolve()
    try:
        target.relative_to(root.resolve())
    except ValueError as error:
        raise ValueError(
            f"URL escapes output root in {source.relative_to(root)}: {value}"
        ) from error
    return target, unquote(parsed.fragment)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate_html_site.py <site-dir>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    index = root / "index.html"
    if not index.is_file():
        raise ValueError("site must contain index.html")

    pages: dict[Path, PageParser] = {}
    for page in sorted(root.rglob("*.html")):
        page_text = page.read_text(encoding="utf-8")
        if any(marker in page_text for marker in ("/home/", "/tmp/", "/Users/")):
            raise ValueError(f"absolute filesystem path leaked into {page.relative_to(root)}")
        if "Content-Security-Policy" not in page_text:
            raise ValueError(f"CSP meta policy missing from {page.relative_to(root)}")
        parser = PageParser()
        parser.feed(page_text)
        parser.close()
        if parser.errors:
            raise ValueError(f"{page.relative_to(root)}: {'; '.join(parser.errors)}")
        pages[page.resolve()] = parser

    if not pages:
        raise ValueError("site must contain at least one HTML page")
    for page, parser in pages.items():
        for link in parser.links:
            target, fragment = resolve_local(root, page, link)
            if target is None:
                continue
            if not target.is_file():
                raise ValueError(f"broken local link in {page.relative_to(root)}: {link}")
            if fragment:
                target_parser = pages.get(target.resolve())
                if target_parser is None or fragment not in target_parser.ids:
                    raise ValueError(f"broken local anchor in {page.relative_to(root)}: {link}")

    script = (root / "search.js").read_text(encoding="utf-8")
    for sink in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval("):
        if sink in script:
            raise ValueError(f"unsafe browser search sink: {sink}")

    search = json.loads((root / "search-index.json").read_text(encoding="utf-8"))
    if search.get("schemaVersion") != "cjdoc.search-index/3":
        raise ValueError("unexpected search index schemaVersion")
    entries = search.get("entries")
    if not isinstance(entries, list):
        raise ValueError("search index entries must be an array")
    ids = [entry.get("id") for entry in entries]
    if ids != sorted(ids) or len(ids) != len(set(ids)):
        raise ValueError("search index IDs must be sorted and unique")
    expected = {"id", "name", "qualifiedName", "kind", "packageName", "summary", "href"}
    for entry in entries:
        if set(entry) != expected:
            raise ValueError(f"invalid search entry fields for {entry.get('id')}")
        target, fragment = resolve_local(root, root / "search-index.json", entry["href"])
        target_parser = pages.get(target.resolve()) if target is not None else None
        if target_parser is None or (fragment and fragment not in target_parser.ids):
            raise ValueError(f"broken search target: {entry['href']}")

    print(f"validated {len(pages)} HTML pages and {len(entries)} search entries")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"HTML site validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
