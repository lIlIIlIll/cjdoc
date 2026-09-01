#!/usr/bin/env python3
"""Validate every cjdoc HTML page, local link, search target, and script sink."""

from __future__ import annotations

import hashlib
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

try:
    from .strict_json import strict_loads
except ImportError:  # Direct script execution.
    from strict_json import strict_loads

EXPECTED_CSP = (
    "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; "
    "base-uri 'none'; form-action 'none'"
)
VOID_ELEMENTS = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
CANONICAL_SEARCH_JS_SHA256 = "81090d635c3e3f087911ffd053a1c7cd047b333a0396e8e336301fd6bad3d908"
CANONICAL_THEME_BOOTSTRAP_JS_SHA256 = "79fe532a96603bce52c49d9fd92cea58503875a0c61f5d3475f11c337f960642"


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.ids: set[str] = set()
        self.links: list[str] = []
        self.errors: list[str] = []
        self.script_depth = 0
        self.stack: list[str] = []
        self.csp_policies: list[str] = []
        self.script_sources: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        lowered_tag = tag.lower()
        if lowered_tag in {"iframe", "object", "embed"}:
            self.errors.append(f"forbidden element <{tag}>")
        attribute_names = [name.lower() for name, _ in attrs]
        seen_attributes: set[str] = set()
        for name in attribute_names:
            if name in seen_attributes:
                self.errors.append(f"duplicate attribute {name!r} on <{tag}>")
            seen_attributes.add(name)
        values = {name.lower(): value for name, value in attrs}
        if lowered_tag == "style":
            self.errors.append("inline style element is forbidden")
        if lowered_tag not in VOID_ELEMENTS:
            self.stack.append(lowered_tag)
        if lowered_tag == "script":
            self.script_depth += 1
            source = values.get("src")
            if not source:
                self.errors.append("inline script is forbidden")
            else:
                self.script_sources.append(source)
            if not self.csp_policies:
                self.errors.append("CSP must precede every script")
            if source and source.rsplit("/", 1)[-1] == "theme-bootstrap.js":
                if len(attribute_names) != 1 or set(attribute_names) != {"src"}:
                    self.errors.append("theme bootstrap script must have only src attribute")
            elif (
                len(attribute_names) != 2
                or set(attribute_names) != {"defer", "src"}
                or values.get("defer") is not None
            ):
                self.errors.append("script must have only defer and src attributes")
        if lowered_tag == "meta" and (values.get("http-equiv") or "").lower() == "content-security-policy":
            if self.stack != ["html", "head"]:
                self.errors.append("CSP meta must be a direct child of head")
            self.csp_policies.append(values.get("content") or "")
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
            elif lowered == "style":
                self.errors.append("inline style attribute is forbidden")

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        lowered = tag.lower()
        if lowered not in VOID_ELEMENTS:
            self.handle_endtag(tag)

    def handle_endtag(self, tag: str) -> None:
        lowered = tag.lower()
        if lowered in VOID_ELEMENTS:
            self.errors.append(f"void element </{tag}> must not have an end tag")
            return
        if not self.stack or self.stack[-1] != lowered:
            expected = self.stack[-1] if self.stack else "none"
            self.errors.append(f"mismatched end tag </{tag}> (expected {expected})")
            return
        self.stack.pop()
        if lowered == "script" and self.script_depth:
            self.script_depth -= 1

    def handle_data(self, data: str) -> None:
        if self.script_depth and data.strip():
            self.errors.append("inline script content is forbidden")

    def close(self) -> None:
        super().close()
        if self.stack:
            self.errors.append(f"unclosed element <{self.stack[-1]}>")


def resolve_local(root: Path, source: Path, value: str) -> tuple[Path | None, str]:
    parsed = urlsplit(value)
    if parsed.scheme:
        if parsed.scheme.lower() not in {"http", "https", "mailto"}:
            raise ValueError(f"unsafe URL scheme in {source.relative_to(root)}: {value}")
        return None, ""
    if parsed.netloc:
        raise ValueError(f"protocol-relative URL in {source.relative_to(root)}: {value}")
    raw_segments = parsed.path.split("/")
    decoded_path = unquote(parsed.path)
    decoded_segments = decoded_path.split("/")
    for index, segment in enumerate(decoded_segments):
        if segment in {".", ".."} and (
            index >= len(raw_segments) or raw_segments[index] != segment
        ):
            raise ValueError(
                f"percent-encoded dot segment in {source.relative_to(root)}: {value}"
            )
    if decoded_path.startswith("/"):
        raise ValueError(f"absolute local URL in {source.relative_to(root)}: {value}")
    target = (source.parent / decoded_path).resolve() if decoded_path else source.resolve()
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
        parser = PageParser()
        parser.feed(page_text)
        parser.close()
        if parser.errors:
            raise ValueError(f"{page.relative_to(root)}: {'; '.join(parser.errors)}")
        if parser.csp_policies != [EXPECTED_CSP]:
            raise ValueError(
                f"{page.relative_to(root)}: expected one exact CSP meta policy"
            )
        relative = page.relative_to(root)
        prefix = "../" * len(relative.parent.parts)
        expected_scripts = [
            prefix + "theme-bootstrap.js",
            prefix + "search-index.js",
            prefix + "search.js",
        ]
        if parser.script_sources != expected_scripts:
            raise ValueError(
                f"{relative}: expected exact canonical script references"
            )
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

    script_paths = {
        path.relative_to(root).as_posix() for path in root.rglob("*.js")
    }
    if script_paths != {"search.js", "search-index.js", "theme-bootstrap.js"}:
        raise ValueError("site must contain only the canonical script set")
    theme_bootstrap_bytes = (root / "theme-bootstrap.js").read_bytes()
    if hashlib.sha256(theme_bootstrap_bytes).hexdigest() != CANONICAL_THEME_BOOTSTRAP_JS_SHA256:
        raise ValueError("theme-bootstrap.js differs from the canonical renderer script")
    theme_bootstrap = theme_bootstrap_bytes.decode("utf-8")
    script_bytes = (root / "search.js").read_bytes()
    if hashlib.sha256(script_bytes).hexdigest() != CANONICAL_SEARCH_JS_SHA256:
        raise ValueError("search.js differs from the canonical renderer script")
    script = script_bytes.decode("utf-8")
    for script_name, script_text in (
        ("theme bootstrap", theme_bootstrap),
        ("browser search", script),
    ):
        for sink in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval("):
            if sink in script_text:
                raise ValueError(f"unsafe {script_name} sink: {sink}")

    search_text = (root / "search-index.json").read_text(encoding="utf-8")
    search = strict_loads(search_text, description="HTML search index")
    search_script = (root / "search-index.js").read_text(encoding="utf-8")
    prefix = "globalThis.__CJDOC_SEARCH_INDEX__ = "
    suffix = ";\n"
    if not search_script.startswith(prefix) or not search_script.endswith(suffix):
        raise ValueError("search-index.js must contain only the generated search assignment")
    embedded_search = search_script[len(prefix) : -len(suffix)]
    if embedded_search != search_text.strip() or \
            strict_loads(embedded_search, description="embedded HTML search index") != search:
        raise ValueError("search-index.js payload differs from search-index.json")
    if search.get("schemaVersion") != "cjdoc.search-index/4":
        raise ValueError("unexpected search index schemaVersion")
    entries = search.get("entries")
    if not isinstance(entries, list):
        raise ValueError("search index entries must be an array")
    ids = [entry.get("id") for entry in entries]
    if len(ids) != len(set(ids)):
        raise ValueError("search index IDs must be unique")
    expected = {"id", "canonicalId", "exposure", "name", "qualifiedName", "kind",
                "packageName", "summary", "href"}
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
    except (OSError, ValueError) as error:
        print(f"HTML site validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
