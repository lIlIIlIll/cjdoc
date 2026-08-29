#!/usr/bin/env python3
"""Validate cjdoc's generated static HTML site using only the Python stdlib."""

from __future__ import annotations

import json
import sys
from html.parser import HTMLParser
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.ids: set[str] = set()
        self.links: list[str] = []
        self.errors: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        lowered_tag = tag.lower()
        if lowered_tag == "script":
            attributes = dict(attrs)
            if attributes.get("src") not in {"search.js", "../search.js"} or "defer" not in attributes:
                self.errors.append("only the managed deferred search.js script is allowed")
        elif lowered_tag in {"iframe", "object", "embed"}:
            self.errors.append(f"forbidden element <{tag}>")
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


def fail(message: str) -> None:
    raise ValueError(message)


def resolve_local(root: Path, source: Path, value: str) -> tuple[Path | None, str]:
    parsed = urlsplit(value)
    if parsed.scheme or parsed.netloc:
        return None, ""
    if parsed.path.startswith("/"):
        fail(f"absolute local URL in {source.relative_to(root)}: {value}")
    target = (source.parent / parsed.path).resolve() if parsed.path else source.resolve()
    try:
        target.relative_to(root.resolve())
    except ValueError:
        fail(f"URL escapes output root in {source.relative_to(root)}: {value}")
    return target, parsed.fragment


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate_html_site.py <site-dir>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    if not root.is_dir():
        fail(f"site directory does not exist: {root}")

    html_files = sorted(root.rglob("*.html"))
    if not html_files or not (root / "index.html").is_file():
        fail("site must contain index.html")
    parsed_pages: dict[Path, PageParser] = {}
    for page in html_files:
        text = page.read_text(encoding="utf-8")
        if "/home/" in text or "/tmp/" in text:
            fail(f"absolute filesystem path leaked into {page.relative_to(root)}")
        parser = PageParser()
        parser.feed(text)
        parser.close()
        if parser.errors:
            fail(f"{page.relative_to(root)}: {'; '.join(parser.errors)}")
        parsed_pages[page.resolve()] = parser

    for page, parser in parsed_pages.items():
        for link in parser.links:
            target, fragment = resolve_local(root, page, link)
            if target is None:
                continue
            if not target.is_file():
                fail(f"broken link in {page.relative_to(root.resolve())}: {link}")
            if fragment:
                target_parser = parsed_pages.get(target)
                if target_parser is None or fragment not in target_parser.ids:
                    fail(f"broken anchor in {page.relative_to(root.resolve())}: {link}")

    search_path = root / "search-index.json"
    search_script = root / "search.js"
    if not search_script.is_file():
        fail("site must contain search.js")
    script_text = search_script.read_text(encoding="utf-8")
    if "innerHTML" in script_text or "document.write" in script_text:
        fail("search.js must construct results without HTML injection sinks")
    for page in html_files:
        page_text = page.read_text(encoding="utf-8")
        if "data-cjdoc-search" not in page_text or "data-cjdoc-results" not in page_text:
            fail(f"search UI missing from {page.relative_to(root)}")
    search = json.loads(search_path.read_text(encoding="utf-8"))
    if search.get("schemaVersion") != "cjdoc.search-index/2":
        fail("unexpected search index schemaVersion")
    symbols = search.get("symbols")
    if not isinstance(symbols, list):
        fail("search index symbols must be an array")
    ids = [entry.get("id") for entry in symbols]
    if ids != sorted(ids):
        fail("search index entries are not sorted by SymbolId")
    if len(ids) != len(set(ids)):
        fail("search index contains duplicate SymbolId values")
    for entry in symbols:
        required = {"id", "kind", "name", "qualifiedName", "packageName", "visibility", "summary", "url"}
        if set(entry) != required:
            fail(f"search index entry fields do not match schema: {entry.get('id')}")
        url = entry.get("url")
        if not isinstance(url, str):
            fail("search index entry has no URL")
        parsed = urlsplit(url)
        if parsed.scheme or parsed.netloc or parsed.path.startswith("/"):
            fail(f"search index URL is not a root-relative path: {url}")
        pure = PurePosixPath(parsed.path)
        if ".." in pure.parts:
            fail(f"search index URL escapes output root: {url}")
        target = (root / parsed.path).resolve()
        if not target.is_file():
            fail(f"search index URL target does not exist: {url}")
        if parsed.fragment:
            target_parser = parsed_pages.get(target)
            if target_parser is None or parsed.fragment not in target_parser.ids:
                fail(f"search index anchor does not exist: {url}")

    for page, parser in parsed_pages.items():
        page_text = page.read_text(encoding="utf-8")
        if "Content-Security-Policy" not in page_text:
            fail(f"CSP meta policy missing from {page.relative_to(root)}")
        if 'role="combobox"' not in page_text or 'role="listbox"' not in page_text:
            fail(f"accessible search roles missing from {page.relative_to(root)}")

    print(f"validated {len(html_files)} HTML pages and {len(symbols)} search entries")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"HTML site validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
