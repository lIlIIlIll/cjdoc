#!/usr/bin/env python3
"""Prepare a bounded symbol inventory from explicitly pinned official doc sources.

No network is used unless --download is present. Source-line URLs deliberately
link to the upstream documentation source, not guessed published-site anchors.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tempfile
import urllib.error
import urllib.request

MAX_MANIFEST_BYTES = 1024 * 1024
MAX_SOURCE_BYTES = 4 * 1024 * 1024
MAX_TOTAL_BYTES = 16 * 1024 * 1024
MAX_SOURCES = 64
MAX_ENTRIES = 4096
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
REVISION = re.compile(r"[0-9a-f]{40}\Z")
NAME = re.compile(r"[A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)*\Z")
OFFICIAL_REPOS = {"std": "cangjie_runtime", "stdx": "cangjie_stdx"}
OFFICIAL_PAGES = {
    "stdlib/doc/libs/std_en/collection/collection_package_api/collection_package_class.md": "std.collection",
    "doc/libs_stdx_en/encoding/json/json_package_api/encoding_json_package_classes.md": "stdx.encoding.json",
}


class InventoryError(ValueError):
    """Invalid or unverifiable source bundle."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise InventoryError(message)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


def bounded_read(path: Path, limit: int) -> bytes:
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    require(len(data) <= limit, "file exceeds byte limit")
    return data


def load_manifest(path: Path) -> dict:
    try:
        value = json.loads(bounded_read(path, MAX_MANIFEST_BYTES), object_pairs_hook=unique_object,
                           parse_constant=lambda _: (_ for _ in ()).throw(InventoryError("non-finite JSON number")))
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise InventoryError("invalid manifest JSON") from error
    require(isinstance(value, dict) and value.get("schemaVersion") == "cjdoc.official-source/1", "unsupported manifest schema")
    sources = value.get("sources")
    require(isinstance(sources, list) and 0 < len(sources) <= MAX_SOURCES, "invalid source count")
    return value


def integer(value: object, minimum: int, maximum: int, label: str) -> int:
    require(type(value) is int and minimum <= value <= maximum, "invalid " + label)
    return value


def text(value: object, label: str, limit: int = 2048) -> str:
    require(isinstance(value, str) and 0 < len(value) <= limit and not any(ord(c) < 32 for c in value), "invalid " + label)
    return value


def bundle_path(root: Path, relative: object) -> Path:
    name = text(relative, "bundle path")
    path = PurePosixPath(name)
    require(not path.is_absolute() and all(part not in ("", ".", "..") for part in name.split("/"))
            and "\\" not in name and ":" not in name, "unsafe bundle path")
    target = root.joinpath(*path.parts)
    require(not any(parent.is_symlink() for parent in [target, *target.parents] if parent != root.parent), "symlink bundle path")
    require(target.resolve().is_relative_to(root.resolve()), "bundle path escapes root")
    return target


def pinned_urls(source: dict) -> tuple[str, str]:
    library = source.get("library")
    require(library in OFFICIAL_REPOS, "unsupported official library")
    revision = text(source.get("revision"), "revision", 40)
    require(REVISION.fullmatch(revision) is not None, "revision must be immutable full commit SHA")
    upstream_path = text(source.get("upstreamPath"), "upstream path")
    require(all(part not in ("", ".", "..") for part in upstream_path.split("/"))
            and re.fullmatch(r"[A-Za-z0-9_./-]+\.md", upstream_path) is not None, "unsafe upstream path")
    prefix = "stdlib/doc/" if library == "std" else "doc/"
    require(upstream_path.startswith(prefix), "source must be official documentation")
    repo = "cangjielanguage/" + OFFICIAL_REPOS[library]
    raw = f"https://raw.githubusercontent.com/{repo}/{revision}/{upstream_path}"
    target = f"https://github.com/{repo}/blob/{revision}/{upstream_path}"
    require(source.get("sourceUri") == raw and source.get("targetUri") == target, "unsafe or unpinned source/target URL")
    require(SHA256.fullmatch(text(source.get("sha256"), "source digest", 64)) is not None, "invalid source digest")
    return raw, target


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise InventoryError("source redirects are forbidden")


def fetch_source(url: str) -> bytes:
    # Ignore environment proxies: only the exact allowlisted public host is read.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    request = urllib.request.Request(url, headers={"User-Agent": "cjdoc-official-inventory/1", "Accept-Encoding": "identity"})
    with opener.open(request, timeout=30) as response:
        require(response.status == 200 and response.geturl() == url, "unexpected source response")
        require(response.headers.get("Content-Encoding", "identity") == "identity", "encoded source response forbidden")
        data = response.read(MAX_SOURCE_BYTES + 1)
    require(len(data) <= MAX_SOURCE_BYTES, "source exceeds byte limit")
    return data


def atomic_write(path: Path, data: bytes) -> None:
    require(not path.is_symlink(), "symlink output forbidden")
    require(not any(parent.is_symlink() for parent in path.parents), "symlink output parent forbidden")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".official-", dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def source_excerpt(source: dict, root: Path, download: bool) -> tuple[bytes, Path, int]:
    url, _ = pinned_urls(source)
    location = bundle_path(root, source.get("path"))
    excerpt = source.get("excerpt")
    require(isinstance(excerpt, dict), "missing excerpt provenance")
    start = integer(excerpt.get("startLine"), 1, 1, "excerpt start (source prefix required)")
    end = integer(excerpt.get("endLine"), start, 1000000, "excerpt end")
    expected = text(excerpt.get("sha256"), "excerpt digest", 64)
    require(SHA256.fullmatch(expected) is not None, "invalid excerpt digest")
    if download:
        full = fetch_source(url)
        require(digest(full) == source["sha256"], "upstream source digest mismatch")
        lines = full.splitlines(keepends=True)
        require(len(lines) >= end, "excerpt exceeds upstream source")
        data = b"".join(lines[start - 1:end])
    else:
        data = bounded_read(location, MAX_SOURCE_BYTES)
    require(digest(data) == expected, "excerpt digest mismatch")
    require(b"\r" not in data, "unsupported source line endings")
    require(len(data.splitlines()) == end - start + 1, "excerpt line count mismatch")
    return data, location, len(full) if download else len(data)


def declaration_lines(data: bytes, start: int) -> tuple[dict[int, str], set[int]]:
    lines = data.decode("utf-8").splitlines()
    require(not any("\x00" in line for line in lines), "NUL in source")
    declarations = set()
    fence = False
    for offset, line in enumerate(lines):
        if line == "```cangjie":
            require(not fence, "nested declaration fence")
            fence = True
        elif line == "```":
            fence = False
        elif fence:
            declarations.add(start + offset)
    require(not fence, "unterminated declaration fence")
    return dict(enumerate(lines, start)), declarations


def verified_entry(item: dict, source: dict, context: dict) -> dict:
    require(isinstance(item, dict), "invalid entry")
    package = text(item.get("packageName"), "package")
    require(package == OFFICIAL_PAGES.get(source["upstreamPath"]), "unreviewed official package mapping")
    qualified = text(item.get("qualifiedName"), "qualified name")
    name = text(item.get("name"), "symbol name")
    require(all(NAME.fullmatch(v) is not None for v in [package, qualified, name]), "invalid symbol spelling")
    require(package.startswith(source["library"] + ".") and qualified.startswith(package + ".")
            and qualified.rsplit(".", 1)[1] == name, "symbol outside source library")
    kind = item.get("kind")
    require(kind in ("class", "function", "property"), "unsupported source symbol kind")
    arity = integer(item.get("genericArity"), 0, 32, "generic arity")
    require(kind == "class" or arity == 0, "generic member heading adaptation is unsupported")
    parameters = item.get("parameterTypes")
    require(isinstance(parameters, list) and len(parameters) <= 64, "invalid parameter types")
    parameters = [text(p, "parameter type", 256) for p in parameters]
    line = integer(item.get("line"), 1, 1000000, "anchor line")
    declaration_line = integer(item.get("declarationLine"), line + 1, line + 30, "declaration line")
    heading = text(item.get("heading"), "heading")
    declaration = text(item.get("declaration"), "declaration")
    lines, fences = context["lines"], context["fences"]
    require(lines.get(line) == heading and heading.startswith("##"), "anchor heading not present")
    require(declaration_line in fences and lines.get(declaration_line) == declaration, "fenced declaration not present")
    keyword = {"class": "class", "function": "func", "property": "prop"}[kind]
    require(declaration.startswith(f"public {keyword} {name}") and
            re.match(rf"public {keyword} {re.escape(name)}(?:[<( :]|$)", declaration) is not None,
            "declaration disagrees with symbol")
    # Explicit manifest signatures, not a Cangjie parser. No guessed parameter keys.
    if kind == "function":
        expected_heading = "### func " + name + "(" + ", ".join(parameters) + ")"
        require(heading.replace("\\", "") == expected_heading, "parameter evidence disagrees with heading")
    else:
        require(not parameters, "non-function parameter types")
        suffix = "" if arity == 0 else "<" + ", ".join(chr(84 + i) for i in range(arity)) + ">"
        expected_heading = ("## class " if kind == "class" else "### prop ") + name + suffix
        require(heading.replace("\\", "") == expected_heading, "type/property heading disagrees with symbol")
    owner = item.get("owner", "")
    require(isinstance(owner, str) and (not owner or NAME.fullmatch(owner) is not None), "invalid owner")
    require((kind == "class" and not owner) or (kind != "class" and qualified == owner + "." + name), "invalid member owner")
    if kind == "class":
        require(qualified == package + "." + name, "class qualification not proven")
    else:
        owner_headings = [value for number, value in lines.items() if number < line and value.startswith("## class ")]
        require(bool(owner_headings), "member owner heading not present")
        owner_name = owner_headings[-1][len("## class "):].replace("\\", "").split("<", 1)[0]
        require(owner == package + "." + owner_name, "member owner not proven by heading")
    key = qualified + "|" + kind + "|" + str(arity) + "(" + ",".join("".join(p.split()) for p in parameters) + ")"
    symbol_id = "cjdoc:v2:" + context["id"] + ":" + key
    return {"id": symbol_id, "canonicalId": symbol_id, "name": name, "qualifiedName": qualified,
            "kind": kind, "moduleId": package, "packageName": package, "ownerId": owner,
            "visibility": "public", "semanticState": "partial", "summary": "",
            "source": {"path": source["upstreamPath"],
                       "start": {"line": declaration_line, "column": 1,
                                 "byteOffset": sum(len((v + "\n").encode("utf-8")) for n, v in lines.items() if n < declaration_line)},
                       "end": {"line": declaration_line, "column": len(declaration) + 1,
                               "byteOffset": sum(len((v + "\n").encode("utf-8")) for n, v in lines.items() if n < declaration_line) + len(declaration.encode("utf-8"))}},
            "href": context["target"] + "?plain=1#L" + str(line), "identity": context["identity"],
            "documentSetId": context["id"], "symbolKey": key,
            "relations": [], "references": [], "typeNavigations": []}


def render_source_page(source: dict, data: bytes) -> bytes:
    """Render escaped excerpts with explicit, source-proven type/member anchors."""
    target = pinned_urls(source)[1]
    parts = ['<!doctype html><html lang="en"><head><meta charset="utf-8">',
             '<meta name="viewport" content="width=device-width,initial-scale=1">',
             '<meta http-equiv="Content-Security-Policy" content="default-src &quot;none&quot;; base-uri &quot;none&quot;">',
             "<title>Official documentation source excerpt</title></head><body>",
             "<h1>Official documentation source excerpt</h1>",
             "<p>Source-verified excerpt, not an SDK compatibility claim or a complete library.</p>",
             '<p><a href="' + html.escape(target, quote=True) + '">Pinned upstream source</a>; CC-BY-4.0.</p>',
             "<p>Revision: " + source["revision"] + "; source SHA-256: " + source["sha256"] + "</p>"]
    by_line = {entry["line"]: entry for entry in source["entries"]}
    for number, line in enumerate(data.decode("utf-8").splitlines(), source["excerpt"]["startLine"]):
        if number in by_line:
            entry = by_line[number]
            level = "h2" if entry["kind"] == "class" else "h3"
            title = entry["heading"].lstrip("# ").replace("\\", "")
            parts.append(f'<{level} id="L{number}">' + html.escape(title) + f"</{level}>")
        else:
            parts.append("<pre>" + html.escape(line) + "</pre>")
    parts.append("</body></html>\n")
    return "\n".join(parts).encode("utf-8")



def prepare(manifest_path: Path, bundle: Path, output: Path, *, download: bool = False,
            html_output: Path | None = None) -> dict:
    manifest = load_manifest(manifest_path)
    if html_output is not None:
        require(html_output.parent.resolve() == output.parent.resolve(), "HTML output must be beside inventory")
    documents, entries, provenance, pending = [], [], [], []
    source_ids, paths, keys = set(), set(), set()
    total = 0
    for source in manifest["sources"]:
        require(isinstance(source, dict), "invalid source descriptor")
        source_id = text(source.get("id"), "source id", 128)
        require(re.fullmatch(r"[A-Za-z0-9_-]+", source_id) is not None, "unsafe source id")
        require(source_id not in source_ids, "duplicate source id")
        source_ids.add(source_id)
        raw, target = pinned_urls(source)
        data, location, consumed = source_excerpt(source, bundle, download)
        require(location not in paths, "duplicate bundle path")
        paths.add(location)
        total += consumed
        require(total <= MAX_TOTAL_BYTES, "bundle exceeds byte limit")
        identity = "official-doc-source:" + source["library"] + ":sha256:" + source["sha256"]
        index_identity = "sha256:" + digest(canonical(source))
        descriptor = {"id": source_id, "library": source["library"], "identity": identity,
                      "state": "declared", "source": "official-doc-source", "target": "",
                      "cfg": "", "audience": "external", "language": "en", "revision": "",
                      "apiVersion": "", "documentationRevision": source["revision"],
                      "indexIdentity": index_identity, "baseUrl": target, "moduleId": ""}
        documents.append(descriptor)
        lines, fences = declaration_lines(data, source["excerpt"]["startLine"])
        items = source.get("entries")
        require(isinstance(items, list) and 0 < len(items) <= MAX_ENTRIES, "invalid entry count")
        page_name = source_id + "-" + index_identity[len("sha256:"):] + ".html"
        for item in items:
            entry = verified_entry(item, source, {"id": source_id, "identity": identity, "target": target,
                                                   "lines": lines, "fences": fences})
            key = (identity, entry["symbolKey"])
            require(key not in keys, "duplicate symbol key")
            keys.add(key)
            if html_output is not None:
                entry["href"] = page_name + "#L" + str(item["line"])
            entries.append(entry)
            require(len(entries) <= MAX_ENTRIES, "inventory exceeds entry limit")
        provenance.append({"documentSetId": source_id, "sourceUri": raw, "revision": source["revision"],
                           "sha256": source["sha256"], "excerpt": source["excerpt"],
                           "verification": "pinned-documentation-source-lines",
                           "sdkMapping": "none", "license": "CC-BY-4.0"})
        pending.append((location, data))
        if html_output is not None:
            require(re.fullmatch(r"[A-Za-z0-9_-]+", html_output.name) is not None, "unsafe HTML directory name")
            require(not html_output.is_symlink() and not any(p.is_symlink() for p in html_output.parents), "symlink HTML output forbidden")
            descriptor["baseUrl"] = "./" + html_output.name
            pending.append((html_output / page_name, render_source_page(source, data)))
    for entry in entries:
        if entry["ownerId"]:
            owners = [owner for owner in entries if owner["identity"] == entry["identity"]
                      and owner["qualifiedName"] == entry["ownerId"] and owner["kind"] == "class"]
            require(len(owners) == 1, "member owner missing or ambiguous")
            entry["ownerId"] = owners[0]["id"]
    result = {"schemaVersion": "cjdoc.symbol-index/2", "documentSets": sorted(documents, key=lambda d: d["id"]),
              "project": {"name": "official-documentation-source-selection", "audience": "external"},
              "dependencies": [], "entries": sorted(entries, key=lambda e: e["id"]),
              "provenance": sorted(provenance, key=lambda p: p["documentSetId"])}
    encoded = canonical(result)
    require(len(encoded) <= MAX_TOTAL_BYTES, "inventory exceeds byte limit")
    require(output.resolve() not in paths and output.resolve() != manifest_path.resolve(), "output overlaps source bundle")
    for location, data in pending:
        if download or (html_output is not None and location.parent == html_output):
            atomic_write(location, data)
    atomic_write(output, encoded)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--bundle", required=True, type=Path, help="local excerpt bundle root")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--download", action="store_true", help="explicitly fetch pinned sources and populate bundle")
    parser.add_argument("--html-output", type=Path, help="write local category pages with proven type/member anchors")
    args = parser.parse_args()
    try:
        result = prepare(args.manifest, args.bundle, args.output, download=args.download, html_output=args.html_output)
    except (InventoryError, OSError, UnicodeError, urllib.error.URLError, TypeError, KeyError, RecursionError) as error:
        # Do not leak local paths, proxy configuration, or URL credentials in logs.
        detail = str(error) if isinstance(error, InventoryError) else type(error).__name__
        print("official inventory preparation failed: " + detail, file=sys.stderr)
        return 2
    print(f"prepared {len(result['entries'])} source-verified entries in {len(result['documentSets'])} document sets")
    return 0


if __name__ == "__main__":
    sys.exit(main())
