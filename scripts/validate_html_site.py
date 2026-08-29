#!/usr/bin/env python3
"""Validate cjdoc's minimal static HTML renderer and search index."""

from __future__ import annotations

import json
import sys
from html.parser import HTMLParser
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlsplit


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.ids: set[str] = set()
        self.links: list[str] = []
        self.errors: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        lowered_tag = tag.lower()
        if lowered_tag in {"script", "iframe", "object", "embed"}:
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


def resolve_local(root: Path, source: Path, value: str) -> tuple[Path | None, str]:
    parsed = urlsplit(value)
    if parsed.scheme or parsed.netloc:
        return None, ""
    if parsed.path.startswith("/"):
        raise ValueError(f"absolute local URL in {source.relative_to(root)}: {value}")
    if ".." in PurePosixPath(parsed.path).parts:
        raise ValueError(f"URL escapes output root in {source.relative_to(root)}: {value}")
    target = (source.parent / parsed.path).resolve() if parsed.path else source.resolve()
    target.relative_to(root.resolve())
    return target, unquote(parsed.fragment)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate_html_site.py <site-dir>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    index = root / "index.html"
    if not index.is_file():
        raise ValueError("site must contain index.html")

    page_text = index.read_text(encoding="utf-8")
    if any(marker in page_text for marker in ("/home/", "/tmp/", "/Users/")):
        raise ValueError("absolute filesystem path leaked into index.html")
    if "Content-Security-Policy" not in page_text:
        raise ValueError("CSP meta policy missing from index.html")
    parser = PageParser()
    parser.feed(page_text)
    parser.close()
    if parser.errors:
        raise ValueError("; ".join(parser.errors))

    for link in parser.links:
        target, fragment = resolve_local(root, index, link)
        if target is None:
            continue
        if not target.is_file():
            raise ValueError(f"broken local link: {link}")
        if fragment and (target != index or fragment not in parser.ids):
            raise ValueError(f"broken local anchor: {link}")

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
        if target != index or fragment not in parser.ids:
            raise ValueError(f"broken search target: {entry['href']}")

    print(f"validated 1 HTML page and {len(entries)} search entries")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"HTML site validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
