#!/usr/bin/env python3
"""Validate every cjdoc HTML page, local link, search target, and script sink."""

from __future__ import annotations

import hashlib
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

try:
    from .strict_json import strict_loads
except ImportError:  # Direct script execution.
    from strict_json import strict_loads

EXPECTED_CSP = (
    "default-src 'none'; script-src 'self' file:; style-src 'self' file:; img-src 'self' file:; "
    "base-uri 'none'; form-action 'none'"
)
VOID_ELEMENTS = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
CANONICAL_SEARCH_JS_SHA256 = "4ee2ed6419b9c3eca7ed787107146fd1e4576623a28068f8b7f11765f7e5041f"
CANONICAL_THEME_BOOTSTRAP_JS_SHA256 = "eb22acb6fbd233c77f87a16317ad5f48d171f13519f9113e3120bf6ab6f48ca7"
CANONICAL_SYMBOL_ALIAS_JS_SHA256 = "c3d8038e8c37d201ff30c2bb7018bd7b88730a22046e26918fb173752d16938a"
TAG_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
CLASSIFICATION_CONTROL = re.compile(r"[\x00-\x1f\x7f]")
CLASSIFICATION_ASCII_WHITESPACE = re.compile(r"[ \t\n\r\f\v]*")


def valid_classification_title(value: object) -> bool:
    return (
        isinstance(value, str)
        and 1 <= len(value) <= 256
        and len(value.encode("utf-8")) <= 256
        and CLASSIFICATION_CONTROL.search(value) is None
        and CLASSIFICATION_ASCII_WHITESPACE.fullmatch(value) is None
    )


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
        self.is_alias = False
        self.dialogs: dict[str, set[str]] = {}
        self.dialog_depth = 0
        self.has_shell = False

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
        if lowered_tag == "body":
            self.is_alias = values.get("data-cjdoc-route") == "symbol-alias"
            self.has_shell = "data-cjdoc-page" in values
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
        if lowered_tag == "dialog":
            self.dialog_depth += 1
            identity = values.get("id")
            if identity:
                self.dialogs[identity] = set()
        elif self.dialog_depth and "id" in values:
            for dialog in self.dialogs:
                self.dialogs[dialog].add(values["id"])
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
        if lowered == "dialog" and self.dialog_depth:
            self.dialog_depth -= 1
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


SIDEBAR_PACKAGE_FIELDS = {"id", "label", "href", "types"}
SIDEBAR_TYPE_FIELDS = {"label", "kind", "kindLabel", "href", "members"}
SIDEBAR_MEMBER_FIELDS = {"label", "kind", "kindLabel", "anchor"}
UNSAFE_KEYS = {"__proto__", "constructor", "prototype"}


def byte_sorted(values: list[str]) -> bool:
    return values == sorted(values, key=lambda value: value.encode("utf-8"))


SEARCH_DIALOG_CONTROLS = {
    "cjdoc-search-input", "cjdoc-search-filters", "cjdoc-search-results"}
SETTINGS_DIALOG_CONTROLS = {"cjdoc-settings-title"}


def validate_dialogs(pages: dict[Path, PageParser]) -> None:
    """Both scripted dialogs must keep their control ids on every page."""
    for page, parser in pages.items():
        if parser.is_alias or not parser.has_shell:
            continue
        expected = {
            "cjdoc-search-dialog": SEARCH_DIALOG_CONTROLS,
            "cjdoc-theme-popover": SETTINGS_DIALOG_CONTROLS,
        }
        for identity, controls in expected.items():
            if identity not in parser.dialogs:
                raise ValueError(f"{page.name}: missing dialog {identity}")
            missing = controls - parser.dialogs[identity]
            if missing:
                raise ValueError(
                    f"{page.name}: dialog {identity} is missing {sorted(missing)}")


def validate_sidebar_index(root: Path, pages: dict[Path, PageParser]) -> None:
    source = root / "sidebar-index.js"
    text = source.read_text(encoding="utf-8")
    prefix, suffix = "globalThis.__CJDOC_SIDEBAR_INDEX__=", ";\n"
    if not text.startswith(prefix) or not text.endswith(suffix):
        raise ValueError("sidebar-index.js must contain only its generated assignment")
    sidebar = strict_loads(text[len(prefix):-len(suffix)], description="sidebar-index.js")
    if not isinstance(sidebar, dict) or set(sidebar) != {
            "version", "packages", "types", "members"}:
        raise ValueError("sidebar-index.js must publish version, packages, types and members")
    if sidebar["version"] != 2:
        raise ValueError("sidebar-index.js must publish navigation version 2")
    packages, types, members = sidebar["packages"], sidebar["types"], sidebar["members"]
    if not isinstance(packages, list) or not isinstance(types, dict) or \
            not isinstance(members, dict):
        raise ValueError("sidebar-index.js has an invalid navigation shape")
    if not byte_sorted(list(types)) or not byte_sorted(list(members)):
        raise ValueError("sidebar-index.js keys must be sorted by byte order")
    for group in (types, members):
        if UNSAFE_KEYS & set(group):
            raise ValueError("sidebar-index.js must not publish prototype keys")
    for member in members.values():
        if not isinstance(member, dict) or set(member) != SIDEBAR_MEMBER_FIELDS or \
                any(not isinstance(value, str) or not value for value in member.values()):
            raise ValueError("sidebar-index.js contains an invalid member")
    seen_packages: set[str] = set()
    for package in packages:
        if not isinstance(package, dict) or set(package) != SIDEBAR_PACKAGE_FIELDS:
            raise ValueError("sidebar-index.js contains an invalid package")
        for key in ("id", "label", "href"):
            if not isinstance(package[key], str) or not package[key]:
                raise ValueError("sidebar-index.js package fields must be non-empty strings")
        if package["id"] in seen_packages or package["id"] != package["href"]:
            raise ValueError("sidebar-index.js package identity must be unique and routable")
        seen_packages.add(package["id"])
        target, fragment = resolve_local(root, source, package["href"])
        if target not in pages or fragment:
            raise ValueError(f"broken sidebar-index.js package target: {package['href']}")
        if not isinstance(package["types"], list) or \
                len(package["types"]) != len(set(package["types"])):
            raise ValueError("sidebar-index.js package type list must be unique")
        for type_id in package["types"]:
            if not isinstance(type_id, str) or type_id not in types:
                raise ValueError("sidebar-index.js package references an unknown type")
    for identity, entry in types.items():
        if not isinstance(entry, dict) or set(entry) != SIDEBAR_TYPE_FIELDS:
            raise ValueError("sidebar-index.js contains an invalid type")
        for key in ("label", "kind", "kindLabel", "href"):
            if not isinstance(entry[key], str) or not entry[key]:
                raise ValueError("sidebar-index.js type fields must be non-empty strings")
        target, fragment = resolve_local(root, source, entry["href"])
        if target not in pages or fragment:
            raise ValueError(f"broken sidebar-index.js type target: {entry['href']}")
        if not isinstance(entry["members"], list) or \
                len(entry["members"]) != len(set(entry["members"])):
            raise ValueError("sidebar-index.js type member list must be unique")
        for member_id in entry["members"]:
            if not isinstance(member_id, str) or member_id not in members:
                raise ValueError("sidebar-index.js type references an unknown member")
            anchor = members[member_id]["anchor"]
            if anchor not in pages[target].ids:
                raise ValueError(
                    f"broken sidebar-index.js member anchor: {entry['href']}#{anchor}")
    known_members = {member_id for entry in types.values() for member_id in entry["members"]}
    if known_members != set(members):
        raise ValueError("sidebar-index.js member table must match its type listings")


def main() -> int:
    if len(sys.argv) not in (2, 4) or (len(sys.argv) == 4 and sys.argv[2] != "--publication-root"):
        print("usage: validate_html_site.py <site-dir> [--publication-root <directory>]", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    publication_root = Path(sys.argv[3]).resolve() if len(sys.argv) == 4 else root
    if not root.is_relative_to(publication_root) or not publication_root.is_dir():
        raise ValueError("language site must be inside its publication root")
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
            prefix + "sidebar-index.js",
            prefix + "search.js",
        ]
        if parser.is_alias:
            expected_scripts = [prefix + "symbol-alias.js"]
        if parser.script_sources != expected_scripts:
            raise ValueError(
                f"{relative}: expected exact canonical script references"
            )
        pages[page.resolve()] = parser

    if not pages:
        raise ValueError("site must contain at least one HTML page")
    for page, parser in list(pages.items()):
        for link in parser.links:
            target, fragment = resolve_local(publication_root, page, link)
            if target is None:
                continue
            if not target.is_file():
                raise ValueError(f"broken local link in {page.relative_to(root)}: {link}")
            if fragment:
                target_parser = pages.get(target.resolve())
                if target_parser is None and target.suffix == ".html" and not target.is_relative_to(root):
                    target_parser = PageParser()
                    target_parser.feed(target.read_text(encoding="utf-8"))
                    target_parser.close()
                    if target_parser.errors:
                        raise ValueError(f"invalid linked language page: {target.relative_to(publication_root)}")
                    pages[target.resolve()] = target_parser
                if target_parser is None or fragment not in target_parser.ids:
                    raise ValueError(f"broken local anchor in {page.relative_to(root)}: {link}")

    script_paths = {
        path.relative_to(root).as_posix() for path in root.rglob("*.js")
    }
    if script_paths != {"search.js", "search-index.js", "sidebar-index.js",
                        "theme-bootstrap.js", "symbol-alias.js"}:
        raise ValueError("site must contain only the canonical script set")
    theme_bootstrap_bytes = (root / "theme-bootstrap.js").read_bytes()
    if hashlib.sha256(theme_bootstrap_bytes).hexdigest() != CANONICAL_THEME_BOOTSTRAP_JS_SHA256:
        raise ValueError("theme-bootstrap.js differs from the canonical renderer script")
    theme_bootstrap = theme_bootstrap_bytes.decode("utf-8")
    script_bytes = (root / "search.js").read_bytes()
    if hashlib.sha256(script_bytes).hexdigest() != CANONICAL_SEARCH_JS_SHA256:
        raise ValueError("search.js differs from the canonical renderer script")
    script = script_bytes.decode("utf-8")
    alias_bytes = (root / "symbol-alias.js").read_bytes()
    if hashlib.sha256(alias_bytes).hexdigest() != CANONICAL_SYMBOL_ALIAS_JS_SHA256:
        raise ValueError("symbol-alias.js differs from the canonical renderer script")
    for script_name, script_text in (
        ("theme bootstrap", theme_bootstrap),
        ("browser search", script),
        ("symbol alias", alias_bytes.decode("utf-8")),
    ):
        for sink in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval("):
            if sink in script_text:
                raise ValueError(f"unsafe {script_name} sink: {sink}")

    search_text = (root / "search-index.json").read_text(encoding="utf-8")
    search = strict_loads(search_text, description="HTML search index")
    search_script = (root / "search-index.js").read_text(encoding="utf-8")
    prefix = "globalThis.__CJDOC_SEARCH_INDEX__ = "
    suffix = ";\n"
    signature_marker = ";\nglobalThis.__CJDOC_SEARCH_SIGNATURES__ = "
    if not search_script.startswith(prefix):
        raise ValueError("search-index.js must start with the generated search assignment")
    marker_index = search_script.find(signature_marker, len(prefix))
    if marker_index < 0:
        raise ValueError("search-index.js must include the generated signature assignment")
    if not search_script.endswith(suffix):
        raise ValueError("search-index.js signature assignment must end with a newline")
    embedded_search = search_script[len(prefix) : marker_index]
    signature_text = search_script[marker_index + len(signature_marker) : -len(suffix)]
    signatures = strict_loads(signature_text, description="embedded search signatures")
    if not isinstance(signatures, dict) or any(
        not isinstance(key, str) or not isinstance(value, str)
        for key, value in signatures.items()
    ):
        raise ValueError("embedded search signatures must be a string map")
    if (
        embedded_search != search_text.strip()
        or strict_loads(embedded_search, description="embedded HTML search index") != search
    ):
        raise ValueError("search-index.js payload differs from search-index.json")
    if search.get("schemaVersion") != "cjdoc.search-index/11":
        raise ValueError("unexpected search index schemaVersion")
    if set(search) != {"schemaVersion", "profile", "contract", "projectionId",
                       "scope", "coverage", "modules", "tags", "entries"}:
        raise ValueError("invalid search index fields")
    if not isinstance(search["contract"], dict) or search["contract"].get("version") != "cjdoc.search-contract/2":
        raise ValueError("search index must publish its executable contract")
    entries = search.get("entries")
    if not isinstance(entries, list):
        raise ValueError("search index entries must be an array")
    if any(not isinstance(entry, dict) for entry in entries):
        raise ValueError("search index entries must be objects")
    ids = [entry.get("id") for entry in entries]
    if len(ids) != len(set(ids)):
        raise ValueError("search index IDs must be unique")
    modules = search.get("modules")
    if not isinstance(modules, list):
        raise ValueError("search index modules must be an array")
    module_fields = {"moduleId", "moduleName", "documentSet", "dependency", "dependencyInstanceState"}
    module_ids = set()
    for module in modules:
        if not isinstance(module, dict) or set(module) != module_fields:
            raise ValueError("invalid search module fields")
        if not isinstance(module["moduleId"], str) or not module["moduleId"] or module["moduleId"] in module_ids:
            raise ValueError("search module identities must be non-empty and unique")
        module_ids.add(module["moduleId"])
        if module["moduleName"] is not None and not isinstance(module["moduleName"], str):
            raise ValueError("search module name must be a string or null")
        if any(module[key] is not None and not isinstance(module[key], dict)
               for key in ("documentSet", "dependency")):
            raise ValueError("search module evidence must be an object or null")
        if module["dependencyInstanceState"] not in {
                "recorded", "not_applicable", "unrecorded", "ambiguous"}:
            raise ValueError("invalid search module dependency instance state")
    tags = search.get("tags")
    if not isinstance(tags, list):
        raise ValueError("search index tags must be an array")
    tag_titles: dict[tuple[int, str], str] = {}
    previous_tag: tuple[int, bytes] | None = None
    for tag in tags:
        if not isinstance(tag, dict) or set(tag) != {"scope", "id", "title"}:
            raise ValueError("invalid search tag dictionary entry")
        scope, identifier, title = tag["scope"], tag["id"], tag["title"]
        if type(scope) is not int or not 0 <= scope < len(modules):
            raise ValueError("search tag scope is outside its module table")
        if not isinstance(identifier, str) or not TAG_ID.fullmatch(identifier) or \
                not valid_classification_title(title):
            raise ValueError("search tag identity or title is invalid")
        sort_key = (scope, identifier.encode("utf-8"))
        if previous_tag is not None and sort_key <= previous_tag:
            raise ValueError("search tag dictionary must be unique and sorted by module and ID")
        previous_tag = sort_key
        tag_titles[(scope, identifier)] = title
    coverage = search.get("coverage")
    if not isinstance(coverage, dict) or coverage.get("projectionId") != search.get("projectionId"):
        raise ValueError("search index coverage must describe its own projection")
    if coverage.get("bodyComplete") != (coverage.get("truncatedEntries") == 0):
        raise ValueError("search index coverage must agree with its truncation count")
    required = {"id", "canonicalId", "snapshotId", "scope", "concept", "genericArity",
                "ownerId", "name", "qualifiedName", "kind", "packageName", "ownerName",
                "ownerQualifiedName", "symbolKey", "parameterTypes", "returnType",
                "returnCanonical", "summary", "summaryDisplay", "body", "bodyTruncated",
                "href", "exposures", "sections", "externalDocs", "bindings", "classification"}
    for entry in entries:
        if set(entry) != required:
            raise ValueError(f"invalid search entry fields for {entry.get('id')}")
        if not isinstance(entry["bodyTruncated"], bool) or not isinstance(entry["concept"], bool):
            raise ValueError(f"search entry flags must be booleans: {entry.get('id')}")
        if type(entry["scope"]) is not int:
            raise ValueError(f"search entry scope must be a module index: {entry.get('id')}")
        classification = entry["classification"]
        if not isinstance(classification, dict) or set(classification) != {"group", "tags"} or \
                not isinstance(classification["tags"], list):
            raise ValueError("search entry classification has an invalid shape")
        group = classification["group"]
        if group is not None:
            if not isinstance(group, dict) or set(group) != {
                    "id", "packageName", "ownerId", "title", "order"} or \
                    not isinstance(group["id"], str) or not TAG_ID.fullmatch(group["id"]) or \
                    not isinstance(group["packageName"], str) or not group["packageName"] or \
                    (group["ownerId"] is not None and
                     (not isinstance(group["ownerId"], str) or not group["ownerId"])) or \
                    not valid_classification_title(group["title"]) or \
                    (group["order"] is not None and
                     (type(group["order"]) is not int or not 0 <= group["order"] <= 999999)):
                raise ValueError("search entry group classification is invalid")
        classification_ids: list[str] = []
        for tag in classification["tags"]:
            if not isinstance(tag, dict) or set(tag) != {"id", "title"} or \
                    not isinstance(tag["id"], str) or not TAG_ID.fullmatch(tag["id"]) or \
                    not valid_classification_title(tag["title"]):
                raise ValueError("search entry tag classification is invalid")
            classification_ids.append(tag["id"])
            if not entry["concept"] and tag_titles.get((entry["scope"], tag["id"])) != tag["title"]:
                raise ValueError("search entry tag does not match its scoped dictionary")
        if classification_ids != sorted(set(classification_ids), key=lambda item: item.encode("utf-8")):
            raise ValueError("search entry tags must be unique and sorted by ID")
        if entry["concept"] and classification != {"group": None, "tags": []}:
            raise ValueError("concept search entries must have empty classification")
        if entry["concept"]:
            if entry["scope"] != -1 or any(entry[key] is not None for key in
                    ("packageName", "qualifiedName", "ownerId", "ownerName", "ownerQualifiedName", "symbolKey")):
                raise ValueError("concept search entries must not invent declaration scope")
        elif not 0 <= entry["scope"] < len(modules):
            raise ValueError(f"search entry scope is outside its module table: {entry.get('id')}")
        if entry["snapshotId"] != search["scope"].get("snapshotId"):
            raise ValueError("search entry belongs to another snapshot")
        if type(entry["genericArity"]) is not int or entry["genericArity"] < 0:
            raise ValueError("search entry genericArity must be a non-negative integer")
        for field in ("packageName", "qualifiedName", "ownerId", "ownerName",
                      "ownerQualifiedName", "symbolKey", "returnType", "returnCanonical"):
            if entry[field] is not None and not isinstance(entry[field], str):
                raise ValueError(f"search entry {field} must be a string or null")
        if not isinstance(entry["parameterTypes"], list) or any(
            not isinstance(value, str) for value in entry["parameterTypes"]
        ):
            raise ValueError("search entry parameterTypes must be an array of strings")
        target, fragment = resolve_local(root, root / "search-index.json", entry["href"])
        target_parser = pages.get(target.resolve()) if target is not None else None
        if target_parser is None or (fragment and fragment not in target_parser.ids):
            raise ValueError(f"broken search target: {entry['href']}")
    if coverage.get("truncatedEntries") != sum(entry["bodyTruncated"] for entry in entries):
        raise ValueError("search coverage must count the actual truncated entries")

    api_canonical_ids = {
        entry["canonicalId"] for entry in entries
        if not entry["concept"]
    }
    # An exposure is an alias of its canonical entry, not a second entry, so its
    # signature key comes from the nested exposure rows.
    exposure_ids = {
        exposure["id"] for entry in entries for exposure in entry["exposures"]
    }
    expected_signature_ids = api_canonical_ids | exposure_ids
    if set(signatures) != expected_signature_ids:
        raise ValueError("search signatures must match canonical API and exposure entry IDs")
    validate_dialogs(pages)
    validate_sidebar_index(root, pages)
    print(f"validated {len(pages)} HTML pages and {len(entries)} search entries")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"HTML site validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
