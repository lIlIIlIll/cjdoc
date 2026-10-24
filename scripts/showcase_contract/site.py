"""Portable final-tree inventory, route resolution, and HTML link checks."""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from html.parser import HTMLParser
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlsplit


class ContractError(ValueError):
    """An input or final artifact cannot support the promised showcase behavior."""


def canonical_json(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                      allow_nan=False).encode("utf-8")


def _unique_keys(pairs: list[tuple[str, object]]) -> dict:
    result: dict = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> dict:
    """Reject duplicate fields and nonstandard nonfinite JSON numbers."""
    def invalid_constant(value: str) -> None:
        raise ContractError(f"nonfinite JSON number: {value}")

    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_unique_keys,
                           parse_constant=invalid_constant)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ContractError(f"cannot read JSON artifact {path.name}: {error}") from error
    if not isinstance(value, dict):
        raise ContractError(f"JSON artifact must be an object: {path.name}")
    return value


NAVIGATION_V1 = "cjdoc.navigation-index/1"
NAVIGATION_V2 = "cjdoc.navigation-index/2"


def _navigation_part_pages(value: dict, name: str) -> list[dict]:
    pages = value.get("pages")
    if not isinstance(pages, list) or any(not isinstance(page, dict) for page in pages):
        raise ContractError(f"invalid navigation pages: {name}")
    return pages


def _navigation_child(index_name: str, child: object) -> str:
    """Resolve a continuation to a document-root-relative canonical path."""
    relative_path(child)
    if not child.endswith(".json") or child == index_name:
        raise ContractError(f"navigation continuation is not a new JSON part: {child!r}")
    root = PurePosixPath(index_name).parent
    return child if root == PurePosixPath(".") else (root / child).as_posix()


def load_navigation_index(read, index_name: str) -> dict:
    """Return one readable navigation view, following every continuation.

    `read(name)` returns a parsed object for a document-root-relative path and
    raises when the file is absent. v1 stays frozen-readable for captures made
    before v2 existed; v2 is assembled only when every continuation repeats the
    same snapshot identity and continues the same stable offset sequence, so a
    truncated or interleaved tree cannot pass as a complete enumeration.
    """
    first = read(index_name)
    version = first.get("schemaVersion")
    if version == NAVIGATION_V1:
        # Frozen v1 captures predate the scope/pagination contract and stay
        # readable exactly as published; only the page list is required here.
        _navigation_part_pages(first, index_name)
        return first
    if version != NAVIGATION_V2:
        raise ContractError(f"unsupported navigation schema: {index_name}")
    project = first.get("project")
    scope = first.get("scope")
    if not isinstance(project, dict) or not isinstance(scope, dict):
        raise ContractError(f"navigation scope is missing: {index_name}")
    if not isinstance(project.get("version"), (str, type(None))):
        raise ContractError(f"navigation project version is invalid: {index_name}")
    query_id = first.get("queryId")
    snapshot_id = scope.get("snapshotId")
    if not isinstance(query_id, str) or not query_id.startswith("cjdoc:query:v1:"):
        raise ContractError(f"navigation query identity is invalid: {index_name}")
    if not isinstance(snapshot_id, str) or not snapshot_id.startswith("cjdoc:snapshot:v1:"):
        raise ContractError(f"navigation snapshot identity is invalid: {index_name}")
    first_pagination = first.get("pagination")
    if not isinstance(first_pagination, dict):
        raise ContractError(f"navigation pagination is missing: {index_name}")
    total = first_pagination.get("total")
    parts = first_pagination.get("parts")
    if not isinstance(total, int) or not isinstance(parts, int) or parts < 1 or total < 0:
        raise ContractError(f"navigation pagination bounds are invalid: {index_name}")
    if first_pagination.get("pathBase") != "document-root":
        raise ContractError(f"navigation path base is not the document root: {index_name}")

    merged: list[dict] = []
    visited = {index_name}
    content_complete = True
    expected_offset = 0
    name = index_name
    part = 0
    value = first
    while True:
        pagination = value.get("pagination")
        if not isinstance(pagination, dict):
            raise ContractError(f"navigation part has no pagination: {name}")
        for key, expected in (("part", part), ("parts", parts), ("total", total),
                              ("offset", expected_offset), ("pathBase", "document-root")):
            if pagination.get(key) != expected:
                raise ContractError(
                    f"navigation continuation {name} has inconsistent {key}: "
                    f"{pagination.get(key)!r} != {expected!r}")
        if value.get("project") != project:
            raise ContractError(f"navigation continuation {name} changed the project")
        part_scope = value.get("scope")
        if not isinstance(part_scope, dict) or part_scope.get("snapshotId") != snapshot_id:
            raise ContractError(f"navigation continuation {name} changed the snapshot")
        if value.get("queryId") != query_id:
            raise ContractError(f"navigation continuation {name} changed the query")
        if value.get("apiCollectionState") != first.get("apiCollectionState"):
            raise ContractError(f"navigation continuation {name} changed API collection state")
        completeness = value.get("completeness")
        if not isinstance(completeness, dict) or not isinstance(
                completeness.get("enumerationComplete"), bool) or not isinstance(
                completeness.get("contentComplete"), bool):
            raise ContractError(f"navigation continuation {name} has no completeness state")
        if completeness["enumerationComplete"] != (parts == 1):
            raise ContractError(f"navigation continuation {name} misstates enumeration completeness")
        pages = _navigation_part_pages(value, name)
        if pagination.get("returned") != len(pages):
            raise ContractError(f"navigation continuation {name} returned count is wrong")
        content_complete = content_complete and completeness["contentComplete"]
        merged.extend(pages)
        expected_offset += len(pages)
        child = pagination.get("next")
        if part + 1 == parts:
            if child is not None:
                raise ContractError(f"navigation final part still offers a continuation: {name}")
            break
        if child is None:
            raise ContractError(f"navigation part {part} of {parts} has no continuation: {name}")
        child_name = _navigation_child(index_name, child)
        if child_name in visited:
            raise ContractError(f"navigation continuation loop or duplicate: {child_name}")
        visited.add(child_name)
        part += 1
        name = child_name
        value = read(name)
        if value.get("schemaVersion") != NAVIGATION_V2:
            raise ContractError(f"navigation continuation is not v2: {name}")
    if len(merged) != total:
        raise ContractError(
            f"navigation enumeration is incomplete: {len(merged)} pages != {total} declared")
    return {"schemaVersion": NAVIGATION_V2, "project": project, "scope": scope,
            "queryId": query_id, "apiCollectionState": first.get("apiCollectionState"),
            "completeness": {"enumerationComplete": True, "contentComplete": content_complete},
            "pagination": {**first_pagination, "offset": 0, "returned": len(merged),
                           "part": 0, "parts": parts, "next": None},
            "pages": merged}


def relative_path(value: object) -> str:
    """Validate a canonical, unescaped, root-relative inventory path, not a URL."""
    if not isinstance(value, str) or not value:
        raise ContractError("artifact path must be a nonempty string")
    if (value.startswith("/") or "\\" in value or ":" in value
            or any(ord(c) < 32 or ord(c) == 127 for c in value)
            or "?" in value or "#" in value or "%" in value):
        raise ContractError(f"unsafe artifact path: {value!r}")
    if any(part in ("", ".", "..") for part in value.split("/")):
        raise ContractError(f"noncanonical artifact path: {value!r}")
    return value


# macOS exposes `/var` and `/tmp` as system aliases of `/private/...`, so every
# `tempfile` location contains a symlink component. These are documented system
# aliases rather than attacker-controlled links, so they are normalized before a
# destination is checked for symlink components. Kept in step with
# `scripts/safe_output_root.py`.
_DARWIN_SYSTEM_ALIASES = {
    Path("/var"): Path("/private/var"),
    Path("/tmp"): Path("/private/tmp"),
}


def normalized_destination(path: Path) -> Path:
    """Absolute path with darwin system aliases replaced by their canonical form."""
    candidate = Path(os.path.abspath(os.fspath(path)))
    if sys.platform == "darwin":
        for alias, canonical in _DARWIN_SYSTEM_ALIASES.items():
            try:
                relative = candidate.relative_to(alias)
            except ValueError:
                continue
            try:
                if alias.is_symlink() and alias.resolve(strict=True) == canonical:
                    return canonical / relative
            except OSError:
                pass
    return candidate


def symlinked_parent(path: Path) -> Path | None:
    """Return the first symlinked component of `path`, or None when it is clean."""
    for parent in normalized_destination(path).parents:
        if parent.is_symlink():
            return parent
    return None


class HtmlDocument(HTMLParser):
    def __init__(self, text: str) -> None:
        super().__init__(convert_charrefs=True)
        self.ids: set[str] = set()
        self.duplicates: set[str] = set()
        self.links: list[str] = []
        self.language: str | None = None
        self.base_element = False
        self.feed(text)
        self.close()

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if tag == "html":
            self.language = values.get("lang")
        if tag == "base":
            self.base_element = True
        anchors = [values.get("id")]
        if tag == "a":
            anchors.append(values.get("name"))
        for anchor in set(anchors) - {None, ""}:
            if anchor in self.ids:
                self.duplicates.add(anchor)
            self.ids.add(anchor)
        for key in ("href", "src"):
            if values.get(key) is not None:
                self.links.append(values[key])

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)


class Site:
    """A snapshot of a static output tree. Construct again after any mutations.

    Symlinks and case-colliding names are forbidden for portable downloads. No
    network requests are made. HTML checks cover href/src and anchors, not CSS
    imports, srcset, script-generated links, or interaction behavior.
    """

    def __init__(self, root: Path) -> None:
        if root.is_symlink() or not root.is_dir():
            raise ContractError(f"site root is not a regular directory: {root}")
        self.root = root.resolve()
        self.files: dict[str, Path] = {}
        self.documents: dict[str, HtmlDocument] = {}
        seen: dict[str, str] = {}
        for path in sorted(self.root.rglob("*")):
            name = path.relative_to(self.root).as_posix()
            relative_path(name)
            if path.is_symlink():
                raise ContractError(f"symlink in published tree: {name}")
            key = name.casefold()
            if key in seen:
                raise ContractError(f"case-colliding paths: {seen[key]} and {name}")
            seen[key] = name
            if path.is_dir():
                continue
            if not path.is_file():
                raise ContractError(f"nonregular published entry: {name}")
            self.files[name] = path
            if path.suffix.lower() in (".html", ".htm"):
                try:
                    self.documents[name] = HtmlDocument(path.read_text(encoding="utf-8"))
                except (OSError, UnicodeError) as error:
                    raise ContractError(f"cannot parse {name}: {error}") from error

    def file(self, name: str) -> Path:
        relative_path(name)
        if name not in self.files:
            raise ContractError(f"missing published file: {name}")
        return self.files[name]

    def digest(self) -> str:
        """Bind evidence to every byte and relative filename in the final tree."""
        inventory = []
        for name, path in sorted(self.files.items()):
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            inventory.append([name, digest.hexdigest()])
        return hashlib.sha256(canonical_json(inventory)).hexdigest()

    def local_link(self, origin: str, href: str) -> tuple[str, str] | None:
        """Resolve an HTML URL within this tree; allow in-tree ../ navigation."""
        self.file(origin)
        if not isinstance(href, str) or any(ord(c) < 32 or ord(c) == 127 for c in href):
            raise ContractError(f"invalid URL in {origin}: {href!r}")
        try:
            parts = urlsplit(href)
        except ValueError as error:
            raise ContractError(f"invalid URL in {origin}: {href!r}") from error
        if parts.scheme:
            if parts.scheme not in ("https", "http", "mailto", "tel"):
                raise ContractError(f"unsupported URL scheme in {origin}: {href!r}")
            if parts.scheme in ("https", "http"):
                if not parts.hostname or parts.username or parts.password or "\\" in href:
                    raise ContractError(f"unsafe external URL in {origin}: {href!r}")
                hostname = parts.hostname.lower().rstrip(".")
                if hostname == "example.test" or hostname.endswith(".example.test"):
                    raise ContractError(f"test-domain link in published output: {href}")
            return None
        if parts.netloc or parts.path.startswith("/") or "\\" in parts.path:
            raise ContractError(f"nonportable URL in {origin}: {href!r}")
        try:
            path = unquote(parts.path, errors="strict")
            fragment = unquote(parts.fragment, errors="strict")
        except UnicodeError as error:
            raise ContractError(f"invalid UTF-8 URL in {origin}: {href!r}") from error
        if (path.startswith("/") or "\\" in path or ":" in path or "%" in path
                or any(ord(c) < 32 or ord(c) == 127 for c in path + fragment)):
            raise ContractError(f"unsafe decoded URL in {origin}: {href!r}")
        if not path:
            resolved = origin
        else:
            components = list(PurePosixPath(origin).parent.parts)
            for part in path.split("/"):
                if part in ("", "."):
                    continue
                if part == "..":
                    if not components:
                        raise ContractError(f"URL escapes output tree: {origin} -> {href}")
                    components.pop()
                else:
                    components.append(part)
            resolved = "/".join(components)
            if path.endswith("/") or resolved not in self.files and (self.root / resolved).is_dir():
                resolved = f"{resolved}/index.html" if resolved else "index.html"
        self.file(resolved)
        if fragment and resolved in self.documents and fragment not in self.documents[resolved].ids:
            raise ContractError(f"missing anchor: {origin} -> {href}")
        return resolved, fragment

    def validate_links(self) -> None:
        problems: list[str] = []
        for name, document in sorted(self.documents.items()):
            if document.duplicates:
                problems.append(f"{name}: duplicate IDs {sorted(document.duplicates)}")
            if document.base_element:
                problems.append(f"{name}: <base> changes portable link semantics")
            for href in document.links:
                try:
                    self.local_link(name, href)
                except ContractError as error:
                    problems.append(str(error))
        if problems:
            raise ContractError("final-site validation failed:\n" + "\n".join(problems))

    def navigation_target(self, target: dict) -> dict:
        """Resolve semantic selectors through the generated navigation index only."""
        index_name = relative_path(target["index"])
        index = load_navigation_index(lambda name: load_json(self.file(name)), index_name)
        if index.get("project") != target["project"]:
            raise ContractError(f"navigation project/version/audience mismatch: {index_name}")
        pages = index["pages"]
        if "docIr" in target:
            from .routes import inline_route, select_declaration
            declaration, page = select_declaration(self, target, pages)
            if target.get("placement") == "member":
                return inline_route(self, target, declaration, pages, page)
        else:
            matches = [page for page in pages
                       if all(page.get(key) == value for key, value in target["match"].items())]
            if len(matches) != 1:
                raise ContractError(f"navigation target needs exactly one match, got {len(matches)}: "
                                    f"{index_name} {target['match']}")
            page = matches[0]
        return self.checked_navigation_page(target, page)

    def checked_navigation_page(self, target: dict, page: dict) -> dict:
        """Validate one native route; shared by owner and member resolution."""
        index_name = target["index"]
        href = page.get("href")
        if not isinstance(href, str) or not href:
            raise ContractError(f"navigation page has no href: {index_name}")
        parsed = urlsplit(href)
        # Navigation safePath disallows dot segments and absolute routes.
        if parsed.scheme or parsed.netloc or parsed.query:
            raise ContractError(f"nonlocal navigation route: {href}")
        relative_path(parsed.path)
        resolved = self.local_link(index_name, href)
        if resolved is None:
            raise ContractError(f"nonlocal navigation route: {href}")
        name, fragment = resolved
        document = self.documents.get(name)
        if document is None or document.language != target["locale"]:
            raise ContractError(f"HTML language mismatch or missing HTML target: {name}")
        return {"href": name + ("#" + fragment if fragment else ""),
                "symbolId": page.get("symbolId"), "pageId": page.get("id"),
                "semanticState": page.get("semanticState")}
