#!/usr/bin/env python3
"""Serve a captured static cjdoc site as a read-only MCP document source.

This is the baseline arm of the paired evaluation: an agent may read only what
the preserved pre-change binary published for people and scripts -- `llms.txt`,
`llms-full.txt`, the machine indexes and the rendered HTML pages. Doc IR
(`docs.json`), api-surface/coverage reports and repository sources are oracle
material, so the server resolves an explicit allowlist instead of offering a
general file reader; with `--site NAME=PATH` the named sites are the complete
allowlist. Everything it reports about scope comes from the captured indexes,
never from a task description.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import stat
import sys
from typing import Any

sys.dont_write_bytecode = True

PROTOCOL_VERSION = "2025-11-25"
SERVER_NAME = "cjdoc-baseline-docs"
SERVER_VERSION = "1"
NAVIGATION_INDEX = "navigation-index.json"
LANGUAGE_TAGS = ("en", "zh-CN")
MAX_READ_BYTES = 65536
MAX_LIST_LIMIT = 200
DEFAULT_LIST_LIMIT = 50
MAX_SCANNED_ENTRIES = 50000
MAX_INDEX_BYTES = 32 * 1024 * 1024
JSON_INDEX_KINDS = {
    "navigation-index.json": "navigation-index",
    "symbol-index.json": "symbol-index",
    "search-index.json": "search-index",
}
TEXT_DOCUMENTS = {"llms.txt": "llms", "llms-full.txt": "llms"}
DOCUMENT_KINDS = ("llms", "navigation-index", "symbol-index", "search-index", "page")
TOOL_NAMES = ("list_documents", "read_document")


class CorpusError(ValueError):
    """The captured baseline tree cannot be served as-is."""


def _load_json_bounded(path: Path) -> Any:
    try:
        if path.stat().st_size > MAX_INDEX_BYTES:
            raise CorpusError(f"baseline index exceeds {MAX_INDEX_BYTES} bytes: {path.name}")
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CorpusError(f"baseline index is unreadable: {path}: {error}") from error


def _inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def _require_regular(path: Path, root: Path) -> Path:
    """Resolve one existing regular file that stays inside its site root."""
    resolved = Path(os.path.realpath(path))
    if not _inside(resolved, root):
        raise CorpusError(f"document escapes its site root: {path}")
    try:
        metadata = resolved.lstat()
    except OSError as error:
        raise CorpusError(f"document disappeared: {path}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise CorpusError(f"document is not a regular file: {path}")
    return resolved


def _document_kind(name: str) -> str | None:
    if name in TEXT_DOCUMENTS:
        return TEXT_DOCUMENTS[name]
    if name in JSON_INDEX_KINDS:
        return JSON_INDEX_KINDS[name]
    if name.endswith(".html"):
        return "page"
    return None


def _site_language(parts: tuple[str, ...], symbol_index: Path | None) -> str | None:
    for part in reversed(parts):
        if part in LANGUAGE_TAGS:
            return part
    if symbol_index is None:
        return None
    index = _load_json_bounded(symbol_index)
    sets = index.get("documentSets") if isinstance(index, dict) else None
    languages = {
        item.get("language") for item in sets or []
        if isinstance(item, dict) and isinstance(item.get("language"), str)
    }
    return languages.pop() if len(languages) == 1 else None


def _site_scope(navigation: dict, language: str | None) -> dict:
    project = navigation.get("project") if isinstance(navigation.get("project"), dict) else {}
    return {
        "project": project.get("name"),
        "audience": project.get("audience"),
        "version": project.get("version"),
        "language": language,
    }


class Document:
    """One allowlisted file of one captured site."""

    def __init__(self, document_id: str, kind: str, path: Path, site: "Site") -> None:
        self.document_id = document_id
        self.kind = kind
        self.path = path
        self.site = site
        self.bytes = _require_regular(path, site.root).stat().st_size

    def listing_entry(self) -> dict:
        return {
            "document": self.document_id,
            "site": self.site.name,
            "kind": self.kind,
            "language": self.site.scope["language"],
            "bytes": self.bytes,
        }


class Site:
    """One captured documentation site: a directory with a navigation index."""

    def __init__(self, name: str, root: Path, relative: str, navigation: dict,
                 documents: list[Document]) -> None:
        self.name = name
        self.root = root
        self.relative = relative
        self.navigation = navigation
        self.documents = documents
        parts = tuple(relative.split("/"))
        symbol_index = root / "symbol-index.json"
        self.scope = _site_scope(
            navigation, _site_language(parts, symbol_index if symbol_index.is_file() else None))
        self._pages_by_href = {
            page["href"]: page for page in navigation.get("pages") or []
            if isinstance(page, dict) and isinstance(page.get("href"), str)
        }
        self._index_summary: dict[str, dict] = {}

    def page_for(self, document: Document) -> dict | None:
        if document.kind != "page":
            return None
        page = self._pages_by_href.get(document.path.relative_to(self.root).as_posix())
        if page is None:
            return None
        return {key: page.get(key) for key in (
            "id", "kind", "title", "symbolId", "moduleId", "packageName", "semanticState")}

    def scope_for(self, document: Document) -> dict:
        scope = dict(self.scope, site=self.name, documentKind=document.kind)
        page = self.page_for(document)
        if page is not None:
            scope["page"] = page
        counts = self._index_counts(document)
        if counts is not None:
            scope["counts"] = counts
        return scope

    def _index_counts(self, document: Document) -> dict | None:
        """Report what the captured index itself claims, without recomputing scope."""
        if document.kind in ("llms", "page"):
            return None
        if document.document_id not in self._index_summary:
            try:
                index = _load_json_bounded(document.path)
            except CorpusError:
                index = None
            if isinstance(index, dict):
                self._index_summary[document.document_id] = {
                    name: len(index[name]) for name in ("pages", "entries", "documentSets",
                                                        "dependencies")
                    if isinstance(index.get(name), list)
                }
            else:
                self._index_summary[document.document_id] = {}
        return self._index_summary[document.document_id] or None

    def inventory(self) -> dict:
        return {
            "site": self.name,
            "path": self.relative,
            "project": self.scope["project"],
            "audience": self.scope["audience"],
            "version": self.scope["version"],
            "language": self.scope["language"],
            "documents": len(self.documents),
        }


def _walk_files(root: Path, pruned: frozenset[Path] = frozenset()) -> list[Path]:
    """List regular files without following links, in a deterministic order."""
    found: list[Path] = []
    for base, directories, files in os.walk(root, followlinks=False):
        directories[:] = sorted(
            name for name in directories
            if name != ".git" and not os.path.islink(os.path.join(base, name))
            and Path(os.path.realpath(os.path.join(base, name))) not in pruned)
        for name in sorted(files):
            path = Path(base) / name
            if os.path.islink(path) or not stat.S_ISREG(os.lstat(path).st_mode):
                continue
            found.append(path)
            if len(found) > MAX_SCANNED_ENTRIES:
                raise CorpusError(f"baseline tree exceeds {MAX_SCANNED_ENTRIES} files: {root}")
    return found


def _site_documents(root: Path, site_root: Path, site: Site,
                    nested: frozenset[Path]) -> list[Document]:
    """Collect one site's own documents; nested sites are served on their own."""
    relative_site = site_root.relative_to(root).as_posix()
    documents: list[Document] = []
    for path in _walk_files(site_root, nested - {site_root}):
        kind = _document_kind(path.name)
        if kind is None:
            continue
        document_id = f"{relative_site}/{path.relative_to(site_root).as_posix()}"
        documents.append(Document(document_id, kind, path, site))
    documents.sort(key=lambda item: item.document_id)
    return documents


def _build_site(name: str, root: Path, site_root: Path,
                nested: frozenset[Path]) -> Site:
    navigation_path = site_root / NAVIGATION_INDEX
    if not navigation_path.is_file():
        raise CorpusError(f"--site {name} has no {NAVIGATION_INDEX}: {site_root}")
    navigation = _load_json_bounded(navigation_path)
    if not isinstance(navigation, dict):
        raise CorpusError(f"navigation index is not an object: {navigation_path}")
    relative = site_root.relative_to(root).as_posix()
    site = Site(name, site_root, relative, navigation, [])
    site.documents = _site_documents(root, site_root, site, nested)
    return site


def scan_baseline(root: Path, overrides: list[tuple[str, Path]] | None = None) -> list[Site]:
    """Discover captured sites, or serve exactly the explicitly named ones.

    A site is a directory that publishes `navigation-index.json`; nested language
    and dependency directories are each their own site so a language cannot be
    silently substituted for another. With `overrides`, the named sites are the
    complete allowlist: anything else in the tree stays unreachable, which is how
    a run pins which captured documentation an agent may see.
    """
    root = Path(os.path.realpath(root))
    if not root.is_dir():
        raise CorpusError(f"--baseline is not a directory: {root}")
    if overrides:
        allowed: dict[Path, str] = {}
        for name, path in overrides:
            resolved = Path(os.path.realpath(path))
            if not _inside(resolved, root):
                raise CorpusError(f"--site path escapes the baseline root: {path}")
            if not resolved.is_dir():
                raise CorpusError(f"--site path is not a directory: {path}")
            allowed[resolved] = name
        site_roots = sorted(allowed)
        by_root = {site_root: (allowed[site_root], site_root) for site_root in site_roots}
    else:
        site_roots = sorted({Path(os.path.realpath(path.parent))
                             for path in _walk_files(root)
                             if path.name == NAVIGATION_INDEX})
        for site_root in site_roots:
            if not _inside(site_root, root):
                raise CorpusError(f"site escapes the baseline root: {site_root}")
        by_root = {site_root: (site_root.relative_to(root).as_posix(), site_root)
                   for site_root in site_roots}
    # A named nested site is served on its own; its parent must not also hand out
    # the same files under a second identity.
    nested = frozenset(by_root)
    sites = [_build_site(name, root, site_root, nested)
             for site_root, (name, _) in sorted(by_root.items(), key=lambda item: item[1][0])]
    names = [site.name for site in sites]
    if len(set(names)) != len(names):
        raise CorpusError("baseline site names must be unique")
    if not sites:
        raise CorpusError(f"baseline tree publishes no {NAVIGATION_INDEX}: {root}")
    return sites


class Corpus:
    """Read-only document access for one captured baseline tree."""

    def __init__(self, sites: list[Site], max_read_bytes: int = MAX_READ_BYTES) -> None:
        self.sites = sites
        self.max_read_bytes = max_read_bytes
        self.documents = {document.document_id: document
                          for site in sites for document in site.documents}
        self._ordered = sorted(self.documents)

    def inventory(self) -> list[dict]:
        return [site.inventory() for site in self.sites]

    def list_documents(self, arguments: dict) -> dict:
        site = arguments.get("site")
        kind = arguments.get("kind")
        prefix = arguments.get("prefix")
        offset = _integer_argument(arguments, "offset", 0)
        limit = _integer_argument(arguments, "limit", DEFAULT_LIST_LIMIT, minimum=1,
                                  maximum=MAX_LIST_LIMIT)
        if site is not None and site not in {item.name for item in self.sites}:
            raise CorpusError(f"unknown site: {site}")
        if kind is not None and kind not in DOCUMENT_KINDS:
            raise CorpusError(f"unknown kind: {kind}; expected one of {', '.join(DOCUMENT_KINDS)}")
        if prefix is not None and not isinstance(prefix, str):
            raise CorpusError("prefix must be a string")
        selected = [
            self.documents[document_id] for document_id in self._ordered
            if (site is None or self.documents[document_id].site.name == site)
            and (kind is None or self.documents[document_id].kind == kind)
            and (prefix is None or document_id.startswith(prefix))
        ]
        page = selected[offset:offset + limit]
        return {
            "sites": self.inventory(),
            "total": len(selected),
            "offset": offset,
            "returned": len(page),
            "hasMore": offset + len(page) < len(selected),
            "documents": [document.listing_entry() for document in page],
        }

    def read_document(self, arguments: dict) -> dict:
        document_id = arguments.get("document")
        if not isinstance(document_id, str) or not document_id:
            raise CorpusError("document must be a non-empty document id from list_documents")
        document = self.documents.get(document_id)
        if document is None:
            raise CorpusError(f"unknown document: {document_id}")
        offset = _integer_argument(arguments, "offset", 0, minimum=0)
        limit = _integer_argument(arguments, "limit", self.max_read_bytes, minimum=1,
                                  maximum=self.max_read_bytes)
        path = _require_regular(document.path, document.site.root)
        return _read_window(document, path, offset, limit)


def _integer_argument(arguments: dict, name: str, default: int,
                      minimum: int | None = None,
                      maximum: int | None = None) -> int:
    value = arguments.get(name, default)
    if isinstance(value, bool) or not isinstance(value, int):
        raise CorpusError(f"{name} must be an integer")
    if minimum is not None and value < minimum:
        raise CorpusError(f"{name} must be >= {minimum}")
    if maximum is not None and value > maximum:
        raise CorpusError(f"{name} must be <= {maximum} (this request would exceed the read budget)")
    return value


CONTINUATION = 0x80
CONTINUATION_MASK = 0xC0
MAX_RUNE_BYTES = 4


def _align_start(buffer: bytes, lookback: int) -> int:
    """Back up to the rune start that contains the requested byte.

    A continuation byte cannot start a rune, and UTF-8 never needs more than
    three bytes of lookback, so the scan is both correct and bounded. A request
    at or past the end of the buffer has no rune to align to.
    """
    probe = min(lookback, len(buffer))
    while probe > 0 and (probe >= len(buffer)
                         or buffer[probe] & CONTINUATION_MASK == CONTINUATION):
        probe -= 1
        if lookback - probe >= MAX_RUNE_BYTES - 1:
            break
    return probe


def _decode_exact(buffer: bytes, start: int, end: int) -> str | None:
    try:
        return buffer[start:end].decode("utf-8", "strict")
    except UnicodeDecodeError:
        return None


def _window_text(buffer: bytes, start: int, limit: int) -> tuple[str, int, bool, bool]:
    """Decode at most `limit` bytes from `start`, never splitting a rune.

    A window that would end mid-rune is extended by up to three bytes when the
    file has them, so a caller never receives a partial character; when the file
    truly ends mid-rune the prefix is trimmed instead. Bytes that are not UTF-8 at
    all are reported as invalid and never replaced, so a corrupted document cannot
    masquerade as valid text.
    """
    end = min(start + limit, len(buffer))
    adjusted = False
    while True:
        text = _decode_exact(buffer, start, end)
        if text is not None:
            return text, end, adjusted, False
        if end < len(buffer) and end - start < limit + MAX_RUNE_BYTES:
            end += 1
            adjusted = True
            continue
        trimmed = end - 1
        while trimmed > start and _decode_exact(buffer, start, trimmed) is None:
            trimmed -= 1
        # Everything after `trimmed` is the document's own tail. If that tail is
        # not UTF-8, the document is corrupt: trimming further would silently hide
        # the corruption and a resuming caller would loop on the same bytes.
        prefix = _decode_exact(buffer, start, trimmed) or ""
        tail_invalid = _decode_exact(buffer, trimmed, len(buffer)) is None
        if tail_invalid:
            # Skip the whole unreadable tail of this window so a resuming caller
            # makes progress; the corruption is reported, never replaced.
            return prefix, len(buffer), True, True
        return prefix, trimmed, True, not prefix


def _read_window(document: Document, path: Path, offset: int, limit: int) -> dict:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise CorpusError(f"document is not a regular file: {document.document_id}")
        size = metadata.st_size
        # Reading past the end reports the end, not the last character: a caller
        # resuming with `endOffset` must be able to see that it is finished.
        requested = min(offset, size)
        # A read at or past the end has no rune to align to and nothing to return;
        # reporting the end keeps a resuming caller from looping on the last byte.
        lookback = min(MAX_RUNE_BYTES - 1, requested) if requested < size else 0
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            stream.seek(requested - lookback)
            buffer = stream.read(lookback + limit + MAX_RUNE_BYTES)
    finally:
        os.close(descriptor)
    aligned = _align_start(buffer, lookback)
    text, end, boundary, invalid = _window_text(buffer, aligned, limit)
    base = requested - lookback
    adjustments = []
    if aligned != lookback:
        adjustments.append("start")
    if boundary:
        adjustments.append("end")
    return {
        "document": document.document_id,
        "site": document.site.name,
        "kind": document.kind,
        "scope": document.site.scope_for(document),
        "encoding": "utf-8",
        "totalBytes": size,
        "requestedOffset": offset,
        "requestedLimit": limit,
        "offset": base + aligned,
        "endOffset": base + end,
        "returnedBytes": len(text.encode("utf-8")),
        "hasMore": base + end < size,
        "utf8BoundaryAdjusted": "-".join(adjustments) if adjustments else "none",
        "invalidUtf8": invalid,
        "text": text,
    }


def _tool_schemas() -> list[dict]:
    return [
        {
            "name": "list_documents",
            "description": (
                "List the published agent-readable documents of the captured documentation "
                "sites (llms text, navigation/symbol/search indexes, HTML pages). "
                "Deterministic ordering; paginate with offset/limit."
            ),
            "inputSchema": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "site": {"type": "string", "description": "Exact site name from `sites`."},
                    "kind": {"type": "string", "enum": list(DOCUMENT_KINDS)},
                    "prefix": {"type": "string", "description": "Document id prefix filter."},
                    "offset": {"type": "integer", "minimum": 0, "default": 0},
                    "limit": {"type": "integer", "minimum": 1, "maximum": MAX_LIST_LIMIT,
                              "default": DEFAULT_LIST_LIMIT},
                },
            },
            "annotations": {"readOnlyHint": True, "destructiveHint": False,
                            "idempotentHint": True, "openWorldHint": False},
        },
        {
            "name": "read_document",
            "description": (
                "Read a UTF-8 byte window of one listed document. Returns the document "
                "scope taken from the captured indexes, exact byte offsets and whether "
                "more bytes remain."
            ),
            "inputSchema": {
                "type": "object",
                "additionalProperties": False,
                "required": ["document"],
                "properties": {
                    "document": {"type": "string", "minLength": 1},
                    "offset": {"type": "integer", "minimum": 0, "default": 0},
                    "limit": {"type": "integer", "minimum": 1, "maximum": MAX_READ_BYTES,
                              "default": MAX_READ_BYTES},
                },
            },
            "annotations": {"readOnlyHint": True, "destructiveHint": False,
                            "idempotentHint": True, "openWorldHint": False},
        },
    ]


def _error(request_id: Any, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def _result(request_id: Any, result: dict) -> dict:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


class Session:
    """One MCP stdio session over a fixed corpus."""

    def __init__(self, corpus: Corpus) -> None:
        self.corpus = corpus
        self.initialized = False

    def handle(self, message: Any) -> dict | None:
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            return _error(None, -32600, "expected a JSON-RPC 2.0 object")
        method = message.get("method")
        request_id = message.get("id")
        if not isinstance(method, str):
            return _error(request_id, -32600, "request has no method") if "id" in message else None
        if "id" not in message:
            self._notification(method)
            return None
        if method == "initialize":
            return _result(request_id, self._initialize(message.get("params")))
        if method == "ping":
            return _result(request_id, {})
        if not self.initialized:
            return _error(request_id, -32002, "server is not initialized")
        if method == "tools/list":
            return _result(request_id, {"tools": _tool_schemas()})
        if method == "tools/call":
            return self._tools_call(request_id, message.get("params"))
        return _error(request_id, -32601, f"unsupported method: {method}")

    def _notification(self, method: str) -> None:
        if method == "notifications/initialized":
            self.initialized = True

    def _initialize(self, params: Any) -> dict:
        self.initialized = True
        requested = params.get("protocolVersion") if isinstance(params, dict) else None
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": (
                "Captured published documentation only: llms text, machine indexes and "
                "HTML pages. Call list_documents first; every scope value comes from the "
                "captured indexes. Doc IR, api-surface, coverage and repository source are "
                "not available. Protocol requested: "
                + (requested if isinstance(requested, str) else "unspecified")
            ),
        }

    def _tools_call(self, request_id: Any, params: Any) -> dict:
        if not isinstance(params, dict) or not isinstance(params.get("name"), str):
            return _error(request_id, -32602, "tools/call requires params.name")
        name = params["name"]
        arguments = params.get("arguments") or {}
        if not isinstance(arguments, dict):
            return _error(request_id, -32602, "tools/call params.arguments must be an object")
        if name not in TOOL_NAMES:
            return _error(request_id, -32602, f"unknown tool: {name}")
        handler = self.corpus.list_documents if name == "list_documents" else self.corpus.read_document
        try:
            payload = handler(arguments)
        except CorpusError as error:
            return _result(request_id, {
                "content": [{"type": "text", "text": json.dumps(
                    {"error": name, "message": str(error)}, ensure_ascii=False)}],
                "isError": True,
            })
        return _result(request_id, {
            "content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=False,
                                                            separators=(",", ":"))}],
            "isError": False,
        })


def serve(stdin, stdout, corpus: Corpus) -> int:
    session = Session(corpus)
    for raw in stdin:
        if not raw.strip():
            continue
        try:
            message = json.loads(raw)
        except json.JSONDecodeError as error:
            response: dict | None = _error(None, -32700, f"invalid JSON: {error}")
        else:
            if isinstance(message, list):
                response = _error(None, -32600, "JSON-RPC batching is not supported")
            else:
                response = session.handle(message)
        if response is None:
            continue
        stdout.write(json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n")
        stdout.flush()
    return 0


def _parse_site_overrides(values: list[str]) -> list[tuple[str, Path]]:
    overrides: list[tuple[str, Path]] = []
    for value in values:
        name, separator, path = value.partition("=")
        if not separator or not name.strip() or not path.strip():
            raise CorpusError(f"--site requires NAME=PATH: {value}")
        overrides.append((name.strip(), Path(path)))
    return overrides


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--baseline", required=True, type=Path,
                        help="captured static documentation tree")
    parser.add_argument("--site", action="append", default=[], metavar="NAME=PATH",
                        help="name one captured site root explicitly (repeatable)")
    parser.add_argument("--max-read-bytes", type=int, default=MAX_READ_BYTES,
                        help=f"per-read byte cap (default {MAX_READ_BYTES})")
    parser.add_argument("--inventory", action="store_true",
                        help="print the discovered site inventory as JSON and exit")
    args = parser.parse_args(argv)
    try:
        if args.max_read_bytes < 1 or args.max_read_bytes > MAX_READ_BYTES:
            raise CorpusError(f"--max-read-bytes must be 1..{MAX_READ_BYTES}")
        sites = scan_baseline(args.baseline, _parse_site_overrides(args.site))
        corpus = Corpus(sites, args.max_read_bytes)
    except CorpusError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if args.inventory:
        print(json.dumps(corpus.inventory(), ensure_ascii=False, indent=2))
        return 0
    return serve(sys.stdin, sys.stdout, corpus)


if __name__ == "__main__":
    raise SystemExit(main())
